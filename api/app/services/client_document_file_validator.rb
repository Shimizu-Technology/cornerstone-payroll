# frozen_string_literal: true

require "csv"
require "zip"
require "ole/storage"
require "timeout"

# Identifies content without a filename or browser MIME hint. OOXML is inspected
# before any converter sees it, including every entry's actual expanded bytes.
class ClientDocumentFileValidator
  MAX_ZIP_ENTRIES = 1_000
  MAX_EXPANDED_BYTES = 100.megabytes
  TYPES = {
    "pdf" => "application/pdf", "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
    "webp" => "image/webp", "txt" => "text/plain", "csv" => "text/csv",
    "doc" => "application/msword", "xls" => "application/vnd.ms-excel",
    "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  }.freeze
  class InvalidFile < StandardError; end

  attr_reader :content_type

  def initialize(file)
    @file = file
    @extension = File.extname(file.original_filename.to_s).delete(".").downcase
  end

  def validate!
    raise InvalidFile, "must not be empty" if @file.size.to_i <= 0
    raise InvalidFile, "must be 25 MB or smaller" if @file.size.to_i > ClientDocument::MAX_FILE_SIZE
    unless TYPES.key?(@extension)
      raise InvalidFile, "must be one of: #{TYPES.keys.join(', ')}. Macro-enabled files and programs are not supported."
    end

    @file.tempfile.rewind
    bytes = @file.tempfile.read(ClientDocument::MAX_FILE_SIZE + 1)
    raise InvalidFile, "must be 25 MB or smaller" if bytes.bytesize > ClientDocument::MAX_FILE_SIZE
    raise InvalidFile, "could not be read completely. Please choose the file again." unless bytes.bytesize == @file.size.to_i

    detected = Marcel::MimeType.for(StringIO.new(bytes))
    @content_type = TYPES.fetch(@extension)
    case @extension
    when "docx", "xlsx" then validate_office_zip!(bytes)
    when "doc", "xls" then validate_legacy_office!(bytes)
    when "txt", "csv" then validate_text!(bytes, detected)
    else
      mismatch! unless detected == @content_type
    end
    validate_declared_type!
    @content_type
  rescue InvalidFile
    raise
  rescue StandardError
    raise InvalidFile, "could not be read as a supported file. Please export it again as PDF, XLSX, CSV or TXT."
  ensure
    @file.tempfile.rewind
  end

  private

  def mismatch!
    raise InvalidFile, "does not match its file extension. Please export it again in the correct format."
  end

  def validate_declared_type!
    declared = @file.content_type.to_s.split(";").first.to_s.strip.downcase
    # Browsers commonly send these ambiguous MIME values for CSV/TXT/Office.
    # They never decide the stored type: the byte/container checks above do.
    compatible = [ @content_type, "", "application/octet-stream" ]
    compatible += [ "text/plain", "application/vnd.ms-excel" ] if @extension == "csv"
    mismatch! unless compatible.include?(declared)
  end

  def validate_text!(bytes, detected)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    mismatch! unless text.valid_encoding? && !text.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F]/)
    mismatch! unless [ "text/plain", "text/csv", "application/octet-stream" ].include?(detected)
    mismatch! if text.start_with?("#!")
    return unless @extension == "csv"

    CSV.new(text.delete_prefix("\uFEFF"), field_size_limit: 1.megabyte).each do |row|
      raise InvalidFile, "has too many columns. Please split the CSV into smaller files." if row.size > 1_000
    end
  rescue CSV::MalformedCSVError
    raise InvalidFile, "is not a readable CSV. Please export it again as a UTF-8 CSV."
  end

  def validate_office_zip!(bytes)
    mismatch! unless bytes.start_with?("PK\x03\x04".b)
    validate_zip_directory!(bytes)
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      raise InvalidFile, "contains too many items. Please export a smaller Office file." if zip.entries.size > MAX_ZIP_ENTRIES
      expanded = 0
      names = []
      metadata = {}
      zip.each do |entry|
        name = entry.name
        mismatch! if entry.encrypted? || name.start_with?("/", "\\") || name.split(/[\\\/]/).include?("..") || names.include?(name.downcase)
        names << name.downcase
        if name.match?(/vba|macro|activex|embeddings|encryptedpackage/i)
          raise InvalidFile, "contains macros or embedded programs. Please export a macro-free file or PDF."
        end
        if entry.size > MAX_EXPANDED_BYTES || expanded + entry.size > MAX_EXPANDED_BYTES
          raise InvalidFile, "expands to more than 100 MB. Please export a smaller Office file."
        end
        next if entry.directory?

        capture = [ "[Content_Types].xml", "word/document.xml", "xl/workbook.xml" ].include?(name)
        data = +"".b
        entry.get_input_stream do |stream|
          while (chunk = stream.read(64.kilobytes)) && !chunk.empty?
            expanded += chunk.bytesize
            raise InvalidFile, "expands to more than 100 MB. Please export a smaller Office file." if expanded > MAX_EXPANDED_BYTES
            if capture
              raise InvalidFile, "contains an Office section that is too large to preview. Please export a smaller file." if data.bytesize + chunk.bytesize > 5.megabytes
              data << chunk
            end
          end
        end
        metadata[name] = data if capture
      end
      main = @extension == "docx" ? "word/document.xml" : "xl/workbook.xml"
      mismatch! unless names.include?("_rels/.rels") && metadata.key?(main)
      types = safe_xml(metadata.fetch("[Content_Types].xml", ""))
      overrides = types.xpath("//*[local-name()='Override']")
      mismatch! if overrides.any? { |node| node["ContentType"].to_s.match?(/macro|vba|activeX/i) }
      expected = @extension == "docx" ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
      mismatch! unless overrides.any? { |node| node["PartName"] == "/#{main}" && node["ContentType"] == expected }
      root = safe_xml(metadata.fetch(main)).root
      mismatch! unless root&.name == (@extension == "docx" ? "document" : "workbook")
    end
  end

  def validate_zip_directory!(bytes)
    # Bound entries before rubyzip allocates a central-directory object per
    # entry. ZIP64/spanned archives are unnecessary for a 25 MiB Office file.
    offset = bytes.rindex("PK\x05\x06".b)
    mismatch! unless offset && offset + 22 <= bytes.bytesize
    disk, directory_disk, disk_count, total_count, directory_bytes, directory_offset, comment_bytes = bytes.byteslice(offset + 4, 18).unpack("vvvvVVv")
    if total_count > MAX_ZIP_ENTRIES
      raise InvalidFile, "contains too many items. Please export a smaller Office file."
    end
    mismatch! unless disk.zero? && directory_disk.zero? && disk_count == total_count &&
      directory_offset + directory_bytes == offset && offset + 22 + comment_bytes == bytes.bytesize
  end

  def safe_xml(bytes)
    mismatch! if bytes.bytesize > 5.megabytes || bytes.include?("<!DOCTYPE") || bytes.include?("<!ENTITY")
    Nokogiri::XML(bytes) { |config| config.strict.nonet }
  end

  def validate_biff!(bytes)
    mismatch! if bytes.empty?
    offset = 0
    while offset < bytes.bytesize
      mismatch! if offset + 4 > bytes.bytesize
      record, length = bytes.byteslice(offset, 4).unpack("vv")
      mismatch! if offset + 4 + length > bytes.bytesize
      # BIFF BOF substream types: 0x40 Excel 4 macros, 0x06 VB module;
      # FILEPASS denotes encrypted content which cannot be validated here.
      macro = [ 0x0809, 0x0409, 0x0209, 0x0009 ].include?(record) && length >= 4 && [ 0x40, 0x06 ].include?(bytes.byteslice(offset + 6, 2).unpack1("v"))
      if macro || record == 0x002f
        raise InvalidFile, "contains macros or protected content. Please export a macro-free XLSX or PDF."
      end
      if offset.zero?
        mismatch! unless [ 0x0809, 0x0409, 0x0209, 0x0009 ].include?(record) && length >= 4 && bytes.byteslice(6, 2).unpack1("v") == 0x0005
      end
      offset += 4 + length
    end
  end

  def validate_legacy_office!(bytes)
    mismatch! unless bytes.start_with?([ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 ].pack("C*"))
    Timeout.timeout(5) do
      Ole::Storage.open(StringIO.new(bytes)) do |ole|
        names = ole.dirents.map { |entry| entry.name.to_s }
        if names.any? { |name| name.match?(/vba|macro|_VBA_PROJECT|encryptedpackage|objectpool/i) }
          raise InvalidFile, "contains macros or embedded programs. Please export a macro-free XLSX, DOCX or PDF."
        end
        word = names.include?("WordDocument") && (names & %w[0Table 1Table]).any?
        excel = (names & %w[Workbook Book]).any?
        mismatch! unless @extension == "doc" ? word && !excel : excel && !word
        validate_biff!(ole.file.read((names & %w[Workbook Book]).first)) if excel
        mismatch! if word && !ole.file.read("WordDocument").start_with?("\xEC\xA5".b)
      end
    end
  end
end
