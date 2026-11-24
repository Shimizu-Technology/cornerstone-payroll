# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantLogoStorageService do
  subject(:service) { described_class.new }

  def clean(bytes)
    service.clean(StringIO.new(bytes))
  end

  def png_chunk_types(png)
    offset = 8
    types = []
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1("N")
      types << png.byteslice(offset + 4, 4)
      offset += 12 + length
    end
    types
  end

  def webp_chunk_types(webp)
    offset = 12
    types = []
    while offset < webp.bytesize
      length = webp.byteslice(offset + 4, 4).unpack1("V")
      types << webp.byteslice(offset, 4)
      offset += 8 + length + (length.odd? ? 1 : 0)
    end
    types
  end

  def ihdr(width, height)
    [ width, height, 8, 6, 0, 0, 0 ].pack("N2C5")
  end

  describe "PNG" do
    it "keeps the image and drops text, EXIF and timestamp chunks" do
      bytes, type = clean(png_logo)

      expect(type).to eq("image/png")
      expect(png_chunk_types(bytes)).to eq(%w[IHDR IDAT IEND])
      expect(bytes).not_to include("Jordan Example")
      expect(bytes).not_to include("GPS")
    end

    it "refuses damaged files and sizes outside the limits" do
      damaged = png_logo.dup
      damaged.setbyte(40, damaged.getbyte(40) ^ 0xFF)
      expect { clean(damaged) }.to raise_error(described_class::InvalidLogo, /damaged/)
      expect { clean(png_logo.byteslice(0, 60)) }.to raise_error(described_class::InvalidLogo, /damaged/)
      expect { clean(png_logo(width: 16, height: 16)) }.to raise_error(described_class::InvalidLogo, /too small/)
      expect { clean(png_logo(width: 2401, height: 40, metadata: false)) }.to raise_error(described_class::InvalidLogo, /2400 pixels/)
    end

    it "accepts real encoder output: palette, interlaced and 16-bit gray" do
      %w[palette.png interlaced.png gray16.png].each do |name|
        expect(clean(brand_logo_fixture(name)).last).to eq("image/png"), name
      end
    end

    it "refuses empty, short, long or corrupt pixel data" do
      signature = "\x89PNG\r\n\x1A\n".b
      iend = png_chunk("IEND", "")
      header = png_chunk("IHDR", ihdr(64, 64))
      row = "\x00".b + ("\x18\x98\xCF\xFF".b * 64)
      build = ->(data) { signature + header + png_chunk("IDAT", data) + iend }

      [
        build.call(""),
        build.call(Zlib::Deflate.deflate(row * 63)),
        build.call(Zlib::Deflate.deflate(row * 65)),
        build.call("not zlib data".b),
        build.call(Zlib::Deflate.deflate(row * 64).byteslice(0, 20))
      ].each do |bytes|
        expect { clean(bytes) }.to raise_error(described_class::InvalidLogo, /damaged/)
      end
      expect(clean(build.call(Zlib::Deflate.deflate(row * 64))).last).to eq("image/png")
    end

    it "stops inflating a small file that expands past the image size" do
      bomb = "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", ihdr(64, 64)) +
        png_chunk("IDAT", Zlib::Deflate.deflate("\x00".b * 50.megabytes, Zlib::BEST_COMPRESSION)) + png_chunk("IEND", "")
      expect(bomb.bytesize).to be < 1.megabyte
      expect { clean(bomb) }.to raise_error(described_class::InvalidLogo, /damaged/)
    end

    it "refuses a palette image without a palette and split image data" do
      signature = "\x89PNG\r\n\x1A\n".b
      palette_header = png_chunk("IHDR", [ 64, 64, 8, 3, 0, 0, 0 ].pack("N2C5"))
      data = png_chunk("IDAT", Zlib::Deflate.deflate(("\x00".b + ("\x00".b * 64)) * 64))
      expect { clean(signature + palette_header + data + png_chunk("IEND", "")) }.to raise_error(described_class::InvalidLogo, /damaged/)

      rows = Zlib::Deflate.deflate(("\x00".b + ("\x18\x98\xCF\xFF".b * 64)) * 64)
      split = signature + png_chunk("IHDR", ihdr(64, 64)) + png_chunk("IDAT", rows.byteslice(0, 10)) +
        png_chunk("tEXt", "a\x00b".b) + png_chunk("IDAT", rows.byteslice(10..)) + png_chunk("IEND", "")
      expect { clean(split) }.to raise_error(described_class::InvalidLogo, /damaged/)
    end

    it "requires a 13-byte IHDR first and image data before IEND" do
      signature = "\x89PNG\r\n\x1A\n".b
      idat = png_chunk("IDAT", Zlib::Deflate.deflate("\x00".b * 65))
      iend = png_chunk("IEND", "")

      short_header = signature + png_chunk("IHDR", ihdr(64, 64).byteslice(0, 12)) + idat + iend
      long_header = signature + png_chunk("IHDR", ihdr(64, 64) + "\x00".b) + idat + iend
      no_data = signature + png_chunk("IHDR", ihdr(64, 64)) + png_chunk("tEXt", "a\x00b".b) + iend
      [ short_header, long_header, no_data ].each do |bytes|
        expect { clean(bytes) }.to raise_error(described_class::InvalidLogo, /damaged/)
      end
    end
  end

  describe "WebP" do
    it "keeps only allowed chunks, dropping EXIF, XMP, C2PA and INFO, and clears the header flags" do
      bytes, type = clean(webp_logo(extra: [ webp_chunk("C2PA", "manifest-signer".b), webp_chunk("INFO", "camera-owner".b) ]))

      expect(type).to eq("image/webp")
      expect(webp_chunk_types(bytes)).to eq([ "VP8X", "VP8L" ])
      %w[GPS-and-camera xmpmeta manifest-signer camera-owner].each { |text| expect(bytes).not_to include(text) }
      expect(bytes.byteslice(4, 4).unpack1("V")).to eq(bytes.bytesize - 8)
      flags = bytes.getbyte(20)
      expect(flags & 0x0C).to eq(0)
      expect(flags & 0x10).to eq(0x10)
    end

    it "reads simple lossy and lossless files" do
      expect(clean(webp_file(webp_vp8(64, 48))).last).to eq("image/webp")
      expect(clean(webp_file(webp_vp8l(64, 48))).last).to eq("image/webp")
    end

    it "accepts real encoder output: lossy, lossy with alpha and lossless" do
      %w[lossy.webp lossy-alpha.webp lossless.webp].each do |name|
        expect(clean(brand_logo_fixture(name)).last).to eq("image/webp"), name
      end
    end

    it "refuses animated images, real or built by hand" do
      expect { clean(brand_logo_fixture("animated.webp")) }.to raise_error(described_class::InvalidLogo, /Animated/)
      anmf = webp_file(webp_vp8x(64, 64, flags: 0x10), webp_vp8l(64, 64), webp_chunk("ANMF", "\x00".b * 16))
      expect { clean(anmf) }.to raise_error(described_class::InvalidLogo, /Animated/)
      flagged = webp_file(webp_vp8x(64, 64, flags: 0x02), webp_vp8l(64, 64))
      expect { clean(flagged) }.to raise_error(described_class::InvalidLogo, /Animated/)
    end

    it "refuses a corrupt or mismatched bitstream after a valid VP8X" do
      [
        webp_file(webp_vp8x(64, 64, flags: 0), webp_vp8(64, 64, start_code: "\x00\x00\x00".b)),
        webp_file(webp_vp8x(64, 64, flags: 0), webp_vp8(64, 64, partition: 0)),
        webp_file(webp_vp8x(64, 64, flags: 0), webp_vp8(64, 64, partition: 500)),
        webp_file(webp_vp8x(64, 64, flags: 0), webp_vp8(48, 64)),
        webp_file(webp_vp8x(64, 64, flags: 0), webp_chunk("ICCP", "profile".b)),
        webp_file(webp_vp8x(64, 64, flags: 0), webp_vp8l(64, 64), webp_vp8l(64, 64)),
        webp_file(webp_vp8x(64, 64, flags: 0x10), webp_chunk("ALPH", "\x00".b * 4), webp_vp8l(64, 64))
      ].each do |bytes|
        expect { clean(bytes) }.to raise_error(described_class::InvalidLogo, /damaged/)
      end
    end

    it "refuses an oversized canvas" do
      expect { clean(webp_logo(width: 3000, height: 100)) }.to raise_error(described_class::InvalidLogo, /2400 pixels/)
    end

    {
      "VP8X" => 10,
      "VP8 " => 10,
      "VP8L" => 5
    }.each do |chunk_type, minimum|
      it "refuses a #{chunk_type.strip} header shorter than #{minimum} bytes instead of failing" do
        truncated = webp_file(webp_chunk(chunk_type, "\x2F".b + ("\x00".b * (minimum - 2))))
        expect { clean(truncated) }.to raise_error(described_class::InvalidLogo, /damaged/)
      end
    end

    it "refuses chunks that run past the RIFF size, bad signatures and files with no image" do
      valid = webp_file(webp_vp8l(64, 64))
      overstated = valid.dup
      overstated[4, 4] = [ valid.bytesize ].pack("V")
      understated = valid.dup
      understated[4, 4] = [ 10 ].pack("V")
      no_image = webp_file(webp_chunk("ICCP", "profile".b))
      bad_vp8l = webp_file(webp_chunk("VP8L", "\x00".b * 13))
      [ overstated, understated, no_image, bad_vp8l, valid.byteslice(0, 14) ].each do |bytes|
        expect { clean(bytes) }.to raise_error(described_class::InvalidLogo, /damaged|PNG or WebP/)
      end
    end
  end

  it "refuses SVG and other types with a plain message" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="30"/></svg>)
    [ svg, %(<?xml version="1.0"?>#{svg}), "\xFF\xD8\xFF\xE0jpeg".b, "GIF89a".b ].each do |bytes|
      expect { clean(bytes) }.to raise_error(described_class::InvalidLogo, "Upload a PNG or WebP image. SVG isn't supported.")
    end
    expect { clean("") }.to raise_error(described_class::InvalidLogo, /empty/)
    expect { clean(png_logo + ("\x00".b * 1.megabyte)) }.to raise_error(described_class::InvalidLogo, /1 MB/)
  end
end
