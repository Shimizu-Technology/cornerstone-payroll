# frozen_string_literal: true

require "digest"
require "securerandom"
require "zlib"

# A client's employee-app logo: PNG or WebP, checked, cleaned and stored in
# R2. The logo is public (the sign-in screen shows it), so only the chunks that
# draw the image are kept:
# - PNG keeps IHDR, PLTE, IDAT, IEND and the color chunks; text, EXIF and
#   timestamp chunks are dropped. The pixel data must inflate to exactly the
#   size IHDR describes.
# - WebP keeps one still image (VP8 or VP8L, with ALPH and ICCP when present);
#   EXIF, XMP, animation and anything else are dropped or refused.
# SVG isn't accepted: sanitizing it by denylist is unreliable, and phones need
# a raster image for the Home Screen icon.
#
# This checks structure without decoding pixels, so it adds no native image
# library to the API.
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
  # Color type => [channels, allowed bit depths].
  PNG_COLOR_TYPES = {
    0 => [ 1, [ 1, 2, 4, 8, 16 ] ], 2 => [ 3, [ 8, 16 ] ], 3 => [ 1, [ 1, 2, 4, 8 ] ],
    4 => [ 2, [ 8, 16 ] ], 6 => [ 4, [ 8, 16 ] ]
  }.freeze
  # Adam7 passes: x offset, y offset, x step, y step.
  PNG_ADAM7 = [ [ 0, 0, 8, 8 ], [ 4, 0, 8, 8 ], [ 0, 4, 4, 8 ], [ 2, 0, 4, 4 ], [ 0, 2, 2, 4 ], [ 1, 0, 2, 2 ], [ 0, 1, 1, 2 ] ].freeze
  PNG_DAMAGED = "That PNG file is damaged. Export it again and try once more."

  WEBP_BITSTREAMS = [ "VP8 ", "VP8L" ].freeze
  WEBP_KEEP_CHUNKS = [ *WEBP_BITSTREAMS, "VP8X", "ALPH", "ICCP" ].freeze
  WEBP_ANIMATION_CHUNKS = %w[ANIM ANMF].freeze
  # Minimum payload length needed to read each header.
  WEBP_MIN_PAYLOAD = { "VP8X" => 10, "VP8 " => 10, "VP8L" => 5 }.freeze
  WEBP_ANIMATION_FLAG = 0x02
  WEBP_EXIF_FLAG = 0x08
  WEBP_XMP_FLAG = 0x04
  WEBP_DAMAGED = "That WebP file is damaged. Export it again and try once more."
  WEBP_ANIMATED = "Animated images can't be used as a logo. Export a still PNG or WebP."

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  # Cleans and stores the file under a key unique to this upload. The SHA-256
  # still names the content for the public URL, but two uploads of the same
  # file never share an object, so deleting one can't remove another's. The
  # caller saves the returned attributes with its audit row, then deletes only
  # the key it replaced (or this one, if the save fails).
  def store!(company:, file:)
    bytes, content_type = clean(file)
    sha = Digest::SHA256.hexdigest(bytes)
    extension = Company::BRAND_LOGO_EXTENSIONS.fetch(content_type)
    key = StagingStoragePolicy.new_key("tenant-brand/company-#{company.id}/#{sha}-#{SecureRandom.hex(8)}.#{extension}")
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

  # Never raises: a leftover object is logged, and the save it follows stands.
  def delete_object(key)
    @storage.delete(key) if key.present?
  rescue StandardError => e
    Rails.logger.warn("[TenantLogoStorage] Couldn't delete replaced logo #{key}: #{e.class}. Remove it by hand.")
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

  # -- PNG --------------------------------------------------------------------

  def clean_png(bytes)
    offset = PNG_SIGNATURE.bytesize
    kept = [ PNG_SIGNATURE ]
    header = nil
    image_data = +"".b
    data_ended = false
    seen_palette = false
    seen_end = false
    while offset + 12 <= bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      chunk_end = offset + 12 + length
      raise InvalidLogo, PNG_DAMAGED if length > MAX_BYTES || chunk_end > bytes.bytesize

      chunk = bytes.byteslice(offset, length + 12)
      crc = chunk.byteslice(8 + length, 4).unpack1("N")
      raise InvalidLogo, PNG_DAMAGED unless Zlib.crc32(chunk.byteslice(4, length + 4)) == crc

      if header.nil?
        raise InvalidLogo, PNG_DAMAGED unless type == "IHDR" && length == PNG_IHDR_LENGTH

        header = png_header(chunk.byteslice(8, PNG_IHDR_LENGTH))
      elsif type == "IHDR"
        raise InvalidLogo, PNG_DAMAGED
      end
      case type
      when "PLTE" then seen_palette = true
      when "IDAT"
        # Image data must be one unbroken run of IDAT chunks.
        raise InvalidLogo, PNG_DAMAGED if data_ended

        image_data << chunk.byteslice(8, length)
      else
        data_ended = true unless image_data.empty?
      end
      kept << chunk if PNG_KEEP_CHUNKS.include?(type)
      offset = chunk_end
      if type == "IEND"
        seen_end = true
        break
      end
    end
    raise InvalidLogo, PNG_DAMAGED unless seen_end && !image_data.empty?
    raise InvalidLogo, PNG_DAMAGED if header[:color_type] == 3 && !seen_palette

    check_png_pixels!(image_data, png_image_size(header))
    kept.join.b
  end

  def png_header(data)
    width, height, bit_depth, color_type, compression, filter, interlace = data.unpack("N2C5")
    channels, depths = PNG_COLOR_TYPES[color_type]
    unless channels && depths.include?(bit_depth) && compression.zero? && filter.zero? && interlace <= 1
      raise InvalidLogo, PNG_DAMAGED
    end

    check_dimensions!(width, height)
    { width: width, height: height, bits_per_pixel: channels * bit_depth, color_type: color_type, interlaced: interlace == 1 }
  end

  # Bytes of filtered scanlines the pixel data must inflate to.
  def png_image_size(header)
    row = ->(width) { 1 + ((width * header[:bits_per_pixel]) + 7) / 8 }
    return header[:height] * row.call(header[:width]) unless header[:interlaced]

    PNG_ADAM7.sum do |x0, y0, dx, dy|
      width = (header[:width] - x0 + dx - 1) / dx
      height = (header[:height] - y0 + dy - 1) / dy
      width.positive? && height.positive? ? height * row.call(width) : 0
    end
  end

  # Inflates in pieces and stops past the expected size, so a small file
  # can't expand into a large one in memory.
  def check_png_pixels!(compressed, expected)
    inflater = Zlib::Inflate.new
    total = 0
    count = lambda do |piece|
      total += piece.bytesize
      raise InvalidLogo, PNG_DAMAGED if total > expected
    end
    inflater.inflate(compressed, &count)
    raise InvalidLogo, PNG_DAMAGED unless inflater.finished? && total == expected
  rescue Zlib::Error
    raise InvalidLogo, PNG_DAMAGED
  ensure
    inflater&.close
  end

  # -- WebP -------------------------------------------------------------------

  def clean_webp(bytes)
    chunks = webp_chunks(bytes)
    types = chunks.map(&:first)
    raise InvalidLogo, WEBP_ANIMATED if types.intersect?(WEBP_ANIMATION_CHUNKS)

    bitstreams = chunks.select { |type, _| WEBP_BITSTREAMS.include?(type) }
    raise InvalidLogo, WEBP_DAMAGED unless bitstreams.one?

    bitstream_type, bitstream = bitstreams.first
    width, height = bitstream_type == "VP8 " ? vp8_dimensions(bitstream) : vp8l_dimensions(bitstream)
    case types.first
    when "VP8X"
      header = chunks.first.last
      raise InvalidLogo, WEBP_ANIMATED if header.getbyte(8).anybits?(WEBP_ANIMATION_FLAG)

      canvas_width = (header.byteslice(12, 3) + "\0".b).unpack1("V") + 1
      canvas_height = (header.byteslice(15, 3) + "\0".b).unpack1("V") + 1
      raise InvalidLogo, WEBP_DAMAGED unless [ canvas_width, canvas_height ] == [ width, height ]
    when *WEBP_BITSTREAMS
      raise InvalidLogo, WEBP_DAMAGED unless chunks.one?
    else
      raise InvalidLogo, WEBP_DAMAGED
    end
    raise InvalidLogo, WEBP_DAMAGED if types.include?("ALPH") && bitstream_type != "VP8 "
    check_dimensions!(width, height)

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

  # [[type, chunk bytes including its 8-byte header and pad], ...]
  def webp_chunks(bytes)
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

    chunks
  end

  # A lossy key frame: frame tag, start code, dimensions, and a first
  # partition that fits in the chunk.
  def vp8_dimensions(chunk)
    length = chunk.byteslice(4, 4).unpack1("V")
    tag = (chunk.byteslice(8, 3) + "\0".b).unpack1("V")
    key_frame = tag.nobits?(0x01)
    version = (tag >> 1) & 0x07
    partition = tag >> 5
    unless key_frame && version <= 3 && partition.positive? && 10 + partition <= length && chunk.byteslice(11, 3) == "\x9D\x01\x2A".b
      raise InvalidLogo, WEBP_DAMAGED
    end

    chunk.byteslice(14, 4).unpack("v2").map { |value| value & 0x3FFF }
  end

  # A lossless image: signature, dimensions, version 0, and data after the header.
  def vp8l_dimensions(chunk)
    length = chunk.byteslice(4, 4).unpack1("V")
    bits = chunk.byteslice(9, 4).unpack1("V")
    raise InvalidLogo, WEBP_DAMAGED unless chunk.getbyte(8) == 0x2F && (bits >> 29).zero? && length > 5

    [ (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1 ]
  end
end
