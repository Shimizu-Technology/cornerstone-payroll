# frozen_string_literal: true

require "digest"
require "marcel"
require "prawn"

class InvoiceLogoStorageService
  MAX_BYTES = 1.megabyte
  MAX_PIXELS = 4_000_000
  MAX_EDGE = 2_400
  CONTENT_TYPES = %w[image/png image/jpeg].freeze

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  def upload!(profile:, file:)
    raise ArgumentError, "Choose a PNG or JPEG logo" unless file
    raise ArgumentError, "Logo must be 1 MB or smaller" if file.size.to_i > MAX_BYTES

    bytes = file.read(MAX_BYTES + 1)
    file.rewind
    raise ArgumentError, "Logo must be 1 MB or smaller" if bytes.bytesize > MAX_BYTES
    raise ArgumentError, "Logo is empty" if bytes.empty?

    content_type = Marcel::MimeType.for(StringIO.new(bytes), name: file.original_filename)
    raise ArgumentError, "Logo must be a PNG or JPEG" unless CONTENT_TYPES.include?(content_type)
    validate_dimensions!(bytes, content_type)

    # Confirm Prawn can render the file before storing it. SVG and remote image
    # references are deliberately unsupported.
    begin
      Prawn::Document.new { |pdf| pdf.image StringIO.new(bytes), fit: [ 120, 120 ] }.render
    rescue StandardError
      raise ArgumentError, "Logo image could not be rendered"
    end

    extension = content_type == "image/png" ? ".png" : ".jpg"
    key = "invoice-brand/organization-#{profile.organization_id}/profile-#{profile.id}/#{SecureRandom.uuid}#{extension}"
    @storage.upload(key, StringIO.new(bytes), content_type: content_type)
    profile.update!(logo_storage_key: key, logo_content_type: content_type,
                    logo_sha256: Digest::SHA256.hexdigest(bytes), logo_byte_size: bytes.bytesize)
    profile
  rescue StandardError
    begin
      @storage.delete(key) if key.present?
    rescue StandardError => cleanup_error
      Rails.logger.warn("Invoice logo cleanup failed: #{cleanup_error.class}: #{cleanup_error.message}")
    end
    raise
  end

  def remove!(profile:)
    # Issued snapshots can still refer to an earlier immutable object.
    profile.update!(logo_storage_key: nil, logo_content_type: nil, logo_sha256: nil, logo_byte_size: nil)
  end

  def download(snapshot)
    key = snapshot["logo_storage_key"].presence
    return nil unless key

    bytes = @storage.download_with_limit(key, max_bytes: MAX_BYTES)
    raise R2StorageService::DownloadError, "Invoice logo is unavailable" unless bytes
    raise R2StorageService::DownloadError, "Invoice logo checksum mismatch" unless Digest::SHA256.hexdigest(bytes) == snapshot["logo_sha256"]

    bytes
  end

  private

  def validate_dimensions!(bytes, content_type)
    dimensions = content_type == "image/png" ? png_dimensions(bytes) : jpeg_dimensions(bytes)
    width, height = dimensions
    unless width&.positive? && height&.positive? && width <= MAX_EDGE && height <= MAX_EDGE && width * height <= MAX_PIXELS
      raise ArgumentError, "Logo dimensions must fit within 2400 px per side and 4 million pixels"
    end
  end

  def png_dimensions(bytes)
    return [] unless bytes.start_with?("\x89PNG\r\n\x1A\n".b) && bytes.bytesize >= 24

    bytes.byteslice(16, 8).unpack("N2")
  end

  def jpeg_dimensions(bytes)
    return [] unless bytes.start_with?("\xFF\xD8".b)

    offset = 2
    while offset + 4 <= bytes.bytesize
      offset += 1 while bytes.getbyte(offset) == 0xFF
      marker = bytes.getbyte(offset)
      break unless marker
      offset += 1
      next if marker == 0x01 || (0xD0..0xD9).cover?(marker)

      length = bytes.byteslice(offset, 2)&.unpack1("n")
      break unless length && length >= 2 && offset + length <= bytes.bytesize
      if [ 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF ].include?(marker)
        return bytes.byteslice(offset + 3, 4).unpack("n2").reverse if length >= 7
      end
      offset += length
    end
    []
  end
end
