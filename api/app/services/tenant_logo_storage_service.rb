# frozen_string_literal: true

require "digest"

# A client's employee-app logo: PNG or WebP, checked, cleaned and stored in
# R2. The logo is public (the sign-in screen shows it), so only the chunks that
# draw the image are kept:
# - PNG keeps IHDR, PLTE, IDAT, IEND and the color chunks; text, EXIF and
#   timestamp chunks are dropped.
# - WebP keeps the bitstream, alpha, color profile and animation chunks;
#   EXIF, XMP and anything else are dropped.
# SVG isn't accepted: sanitizing it by denylist is unreliable, and phones need
# a raster image for the Home Screen icon.
class TenantLogoStorageService
  class InvalidLogo < StandardError; end

  MAX_BYTES = 1.megabyte
  MAX_EDGE = 2_400
  MAX_PIXELS = 4_000_000
  MIN_EDGE = 32
  UNSUPPORTED_TYPE = "Upload a PNG or WebP image. SVG isn't supported."

  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  PNG_IHDR_LENGTH = 13
  # Critical chunks plus the ancillary chunks that change how the image looks.
  PNG_KEEP_CHUNKS = %w[IHDR PLTE IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT].freeze
  PNG_DAMAGED = "That PNG file is damaged. Export it again and try once more."

  WEBP_KEEP_CHUNKS = [ "VP8 ", "VP8L", "VP8X", "ALPH", "ICCP", "ANIM", "ANMF" ].freeze
  # Minimum payload length needed to read each header.
  WEBP_MIN_PAYLOAD = { "VP8X" => 10, "VP8 " => 10, "VP8L" => 5 }.freeze
  WEBP_EXIF_FLAG = 0x08
  WEBP_XMP_FLAG = 0x04
  WEBP_DAMAGED = "That WebP file is damaged. Export it again and try once more."

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  # Cleans and stores the file under a content-addressed key. Returns the
  # attributes to save on the company. The caller saves them with its audit
  # row, then deletes the replaced object (or this one, if the save fails).
  def store!(company:, file:)
    bytes, content_type = clean(file)
    sha = Digest::SHA256.hexdigest(bytes)
    key = StagingStoragePolicy.new_key("tenant-brand/company-#{company.id}/#{sha}.#{Company::BRAND_LOGO_EXTENSIONS.fetch(content_type)}")
    @storage.upload(key, StringIO.new(bytes), content_type: content_type)
    { brand_logo_storage_key: key, brand_logo_content_type: content_type,
      brand_logo_sha256: sha, brand_logo_byte_size: bytes.bytesize }
  end

  def download(company)
    key = company.brand_logo_storage_key.presence
    return unless key

    bytes = @storage.download_with_limit(key, max_bytes: MAX_BYTES)
    return unless bytes && Digest::SHA256.hexdigest(bytes) == company.brand_logo_sha256

    bytes
  end

  def delete_object(key)
    @storage.delete(key) if key.present?
  rescue StandardError => e
    Rails.logger.warn("Tenant logo delete failed: #{e.class}")
  end

  # Returns [clean_bytes, content_type] or raises InvalidLogo with a message
  # the person uploading can act on.
  def clean(file)
    raise InvalidLogo, UNSUPPORTED_TYPE unless file.respond_to?(:read)
    raise InvalidLogo, "The logo must be 1 MB or smaller" if file.respond_to?(:size) && file.size.to_i > MAX_BYTES

    bytes = file.read(MAX_BYTES + 1).to_s.b
    file.rewind if file.respond_to?(:rewind)
    raise InvalidLogo, "The logo must be 1 MB or smaller" if bytes.bytesize > MAX_BYTES
    raise InvalidLogo, "That file is empty" if bytes.empty?

    if bytes.start_with?(PNG_SIGNATURE)
      [ clean_png(bytes), "image/png" ]
    elsif bytes.bytesize >= 12 && bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"
      [ clean_webp(bytes), "image/webp" ]
    else
      raise InvalidLogo, UNSUPPORTED_TYPE
    end
  end

  private

  def check_dimensions!(width, height)
    raise InvalidLogo, "That image couldn't be read. Export it again as PNG" unless width.to_i.positive? && height.to_i.positive?
    if width > MAX_EDGE || height > MAX_EDGE || width * height > MAX_PIXELS
      raise InvalidLogo, "The logo must be at most #{MAX_EDGE} pixels on each side"
    end
    return unless width < MIN_EDGE || height < MIN_EDGE

    raise InvalidLogo, "The logo is too small. Use one at least #{MIN_EDGE} pixels on each side"
  end

  def clean_png(bytes)
    offset = PNG_SIGNATURE.bytesize
    kept = [ PNG_SIGNATURE ]
    seen_end = false
    seen_data = false
    first = true
    while offset + 12 <= bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      chunk_end = offset + 12 + length
      raise InvalidLogo, PNG_DAMAGED if length > MAX_BYTES || chunk_end > bytes.bytesize

      chunk = bytes.byteslice(offset, length + 12)
      crc = chunk.byteslice(8 + length, 4).unpack1("N")
      raise InvalidLogo, PNG_DAMAGED unless Zlib.crc32(chunk.byteslice(4, length + 4)) == crc

      if first
        raise InvalidLogo, PNG_DAMAGED unless type == "IHDR" && length == PNG_IHDR_LENGTH

        check_dimensions!(*chunk.byteslice(8, 8).unpack("N2"))
      end
      seen_data ||= type == "IDAT"
      kept << chunk if PNG_KEEP_CHUNKS.include?(type)
      first = false
      offset = chunk_end
      if type == "IEND"
        seen_end = true
        break
      end
    end
    raise InvalidLogo, PNG_DAMAGED unless seen_end && seen_data

    kept.join.b
  end

  def clean_webp(bytes)
    riff_size = bytes.byteslice(4, 4).unpack1("V")
    limit = riff_size + 8
    raise InvalidLogo, WEBP_DAMAGED if riff_size < 4 || limit > bytes.bytesize

    offset = 12
    chunks = []
    while offset < limit
      raise InvalidLogo, WEBP_DAMAGED if offset + 8 > limit

      type = bytes.byteslice(offset, 4)
      length = bytes.byteslice(offset + 4, 4).unpack1("V")
      padded = length + (length.odd? ? 1 : 0)
      raise InvalidLogo, WEBP_DAMAGED if offset + 8 + length > limit
      raise InvalidLogo, WEBP_DAMAGED if length < WEBP_MIN_PAYLOAD.fetch(type, 0)

      # The pad byte may be missing on the last chunk; write it back.
      payload = bytes.byteslice(offset + 8, length)
      chunks << [ type, type.b + [ length ].pack("V") + payload + ("\x00".b * (padded - length)) ]
      offset += 8 + padded
    end
    raise InvalidLogo, WEBP_DAMAGED if chunks.empty?

    check_dimensions!(*webp_dimensions(chunks.first))
    raise InvalidLogo, WEBP_DAMAGED unless chunks.any? { |type, _| [ "VP8 ", "VP8L", "ANMF" ].include?(type) }

    kept = chunks.select { |type, _| WEBP_KEEP_CHUNKS.include?(type) }.map do |type, chunk|
      next chunk unless type == "VP8X"

      # Clear the EXIF and XMP flags along with their chunks.
      chunk = chunk.dup
      chunk.setbyte(8, chunk.getbyte(8) & ~(WEBP_EXIF_FLAG | WEBP_XMP_FLAG))
      chunk
    end

    body = "WEBP".b + kept.join.b
    ("RIFF".b + [ body.bytesize ].pack("V") + body).b
  end

  # Header lengths were checked against WEBP_MIN_PAYLOAD before this runs.
  def webp_dimensions((type, chunk))
    case type
    when "VP8X"
      width = (chunk.byteslice(12, 3) + "\0".b).unpack1("V") + 1
      height = (chunk.byteslice(15, 3) + "\0".b).unpack1("V") + 1
      [ width, height ]
    when "VP8 "
      raise InvalidLogo, WEBP_DAMAGED unless chunk.byteslice(11, 3) == "\x9D\x01\x2A".b

      chunk.byteslice(14, 4).unpack("v2").map { |value| value & 0x3FFF }
    when "VP8L"
      raise InvalidLogo, WEBP_DAMAGED unless chunk.getbyte(8) == 0x2F

      bits = chunk.byteslice(9, 4).unpack1("V")
      [ (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1 ]
    else
      raise InvalidLogo, WEBP_DAMAGED
    end
  end
end
