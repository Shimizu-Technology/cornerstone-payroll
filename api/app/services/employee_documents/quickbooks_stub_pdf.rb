# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksStubPdf
    class Invalid < StandardError; end

    # CombinePDF's parser can put raw PDF strings in warnings. Reject such
    # input here without sending the parser's diagnostic to application logs.
    class StrictParser < CombinePDF::PDFParser
      private

      def warn(*)
        raise Invalid, "Use the QuickBooks PDF, not a scan."
      end
    end

    MAX_BYTES = 10.megabytes
    MAX_PAGES = 50
    SSN = /(?<![0-9])[0-9]{3}(?:[^0-9]{0,2}|[\p{Space}\p{Pd}.]+)[0-9]{2}(?:[^0-9]{0,2}|[\p{Space}\p{Pd}.]+)[0-9]{4}(?![0-9])/
    Page = Data.define(:number, :bytes, :text, :issue, :has_image)

    def self.read(file)
      raise Invalid, "Choose a PDF up to 10 MB." unless file.respond_to?(:read) && file.respond_to?(:size) &&
        file.size.between?(1, MAX_BYTES)

      content = file.read(MAX_BYTES + 1)
      raise Invalid, "Choose a PDF up to 10 MB." unless content&.start_with?("%PDF-") && content.bytesize <= MAX_BYTES

      reader = PDF::Reader.new(StringIO.new(content))
      raise Invalid, "Choose a PDF with 1 to 50 pages." unless reader.page_count.between?(1, MAX_PAGES)

      # Split before archival so each employee gets only the selected page.
      # Scan both the original page and the exact bytes that would be stored.
      original_pages = reader.pages
      pages = CombinePDF::PDF.new(StrictParser.new(content, raise_on_encrypted: true)).pages
      raise Invalid, "The PDF page inventory could not be verified." unless pages.size == original_pages.size

      pages.map.with_index(1) do |page, number|
        original_page = original_pages.fetch(number - 1)
        original_text = scan_text(original_page)
        if (issue = issue_for(original_text))
          next Page.new(number:, bytes: nil, text: nil, issue:, has_image: false)
        end

        if page[:Annots].present? || page[:AA].present?
          next Page.new(number:, bytes: nil, text: nil, issue: "unreadable", has_image: false)
        end

        page.except!(:Metadata, :PieceInfo, :Thumb)
        split = CombinePDF.new
        split.info[:CreationDate] = Time.utc(2026)
        split << page
        bytes = split.to_pdf
        archived_page = PDF::Reader.new(StringIO.new(bytes)).page(1)
        archived_text = scan_text(archived_page)
        issue = issue_for(archived_text)
        has_image = !issue && [ original_page, archived_page ].any? do |candidate|
          image_xobjects?(candidate.objects, candidate.xobjects)
        end
        Page.new(number:, bytes: issue ? nil : bytes, text: issue ? nil : archived_text, issue:, has_image:)
      end
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::InvalidPageError,
      CombinePDF::ParsingError, CombinePDF::EncryptionError, EncodingError
      raise Invalid, "Use the QuickBooks PDF, not a scan.", cause: nil
    end

    def self.scan_text(page)
      page.text.unicode_normalize(:nfkc)
    end
    private_class_method :scan_text

    def self.issue_for(text)
      variants = [ text, text.gsub(/(?<=[0-9]) (?=[0-9])/, "") ]
      return "full_ssn" if variants.any? { |variant| variant.lines.any? { |line| /\bSSN\b/i.match?(line) && SSN.match?(line) } }
      return "possible_ssn" if variants.any? { |variant| SSN.match?(variant) }
      return "unreadable" if text.blank? || text.include?("\uFFFD")

      nil
    end
    def self.image_xobjects?(objects, xobjects)
      pending = xobjects.values
      seen = Set.new
      until pending.empty?
        stream = objects.deref(pending.pop)
        next unless stream.is_a?(PDF::Reader::Stream) && seen.add?(stream.object_id)
        return true if stream.hash[:Subtype] == :Image
        next unless stream.hash[:Subtype] == :Form

        resources = objects.deref_hash(stream.hash[:Resources]) || {}
        pending.concat((objects.deref_hash(resources[:XObject]) || {}).values)
      end
      false
    end

    private_class_method :issue_for, :image_xobjects?
  end
end
