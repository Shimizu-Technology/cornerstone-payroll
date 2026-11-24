# frozen_string_literal: true

require "zlib"

# Small, valid logo files built in memory for the tenant logo specs.
module BrandLogoFixtures
  def png_chunk(type, data)
    [ data.bytesize ].pack("N") + type.b + data.b + [ Zlib.crc32(type.b + data.b) ].pack("N")
  end

  # A width x height RGBA PNG, optionally with text and EXIF metadata chunks.
  def png_logo(width: 64, height: 64, metadata: true)
    rows = Array.new(height) { "\x00".b + ("\x18\x98\xCF\xFF".b * width) }.join
    chunks = [ png_chunk("IHDR", [ width, height, 8, 6, 0, 0, 0 ].pack("N2C5")) ]
    if metadata
      chunks << png_chunk("tEXt", "Author\x00Jordan Example".b)
      chunks << png_chunk("eXIf", "MM\x00\x2A\x00\x00\x00\x08GPS".b)
      chunks << png_chunk("tIME", [ 2026, 11, 24, 12, 0, 0 ].pack("nC5"))
    end
    chunks << png_chunk("IDAT", Zlib::Deflate.deflate(rows))
    chunks << png_chunk("IEND", "")
    ("\x89PNG\r\n\x1A\n".b + chunks.join).b
  end

  def webp_chunk(type, data)
    padded = data.b + (data.bytesize.odd? ? "\x00".b : "".b)
    type.b + [ data.bytesize ].pack("V") + padded
  end

  def webp_file(*chunks)
    body = "WEBP".b + chunks.join.b
    ("RIFF".b + [ body.bytesize ].pack("V") + body).b
  end

  def webp_vp8x(width, height, flags: 0x08 | 0x04 | 0x10)
    webp_chunk("VP8X", [ flags, 0, 0, 0 ].pack("C4") + [ width - 1 ].pack("V")[0, 3] + [ height - 1 ].pack("V")[0, 3])
  end

  def webp_vp8l(width, height)
    webp_chunk("VP8L", "\x2F".b + [ (width - 1) | ((height - 1) << 14) ].pack("V") + ("\x00".b * 8))
  end

  def webp_vp8(width, height)
    webp_chunk("VP8 ", "\x00\x00\x00".b + "\x9D\x01\x2A".b + [ width, height ].pack("v2") + ("\x00".b * 6))
  end

  # An extended WebP header (VP8X) with EXIF, XMP and extra chunks around a
  # lossless bitstream header. The specs check headers and metadata only.
  def webp_logo(width: 64, height: 64, extra: [])
    webp_file(webp_vp8x(width, height), webp_vp8l(width, height),
      webp_chunk("EXIF", "Exif\x00\x00GPS-and-camera".b), webp_chunk("XMP ", "<x:xmpmeta>owner</x:xmpmeta>".b), *extra)
  end

  def logo_upload(bytes, filename: "logo.png", content_type: "image/png")
    file = Tempfile.new([ "logo", File.extname(filename) ])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: filename)
  end
end

RSpec.configure do |config|
  config.include BrandLogoFixtures
end
