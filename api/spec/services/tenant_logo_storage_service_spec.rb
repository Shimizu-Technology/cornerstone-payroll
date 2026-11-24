# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantLogoStorageService do
  subject(:service) { described_class.new }

  def clean(bytes)
    service.clean(StringIO.new(bytes))
  end

  def chunk_types(png)
    offset = 8
    types = []
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1("N")
      types << png.byteslice(offset + 4, 4)
      offset += 12 + length
    end
    types
  end

  describe "PNG" do
    it "keeps the image and drops text, EXIF and timestamp chunks" do
      bytes, type = clean(png_logo)

      expect(type).to eq("image/png")
      expect(chunk_types(bytes)).to eq(%w[IHDR IDAT IEND])
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
  end

  describe "WebP" do
    it "drops EXIF and XMP chunks and clears their header flags" do
      bytes, type = clean(webp_logo)

      expect(type).to eq("image/webp")
      expect(bytes).not_to include("GPS-and-camera")
      expect(bytes).not_to include("xmpmeta")
      expect(bytes.byteslice(4, 4).unpack1("V")).to eq(bytes.bytesize - 8)
      flags = bytes.getbyte(20)
      expect(flags & 0x0C).to eq(0)
      expect(flags & 0x10).to eq(0x10)
    end

    it "refuses an oversized canvas" do
      expect { clean(webp_logo(width: 3000, height: 100)) }.to raise_error(described_class::InvalidLogo, /2400 pixels/)
    end
  end

  describe "SVG" do
    it "removes comments, metadata and editor attributes and keeps internal references" do
      bytes, type = clean(svg_logo('<use href="#g"/>'))

      expect(type).to eq("image/svg+xml")
      expect(bytes).not_to include("Jordan Example")
      expect(bytes).not_to include("inkscape:version")
      expect(bytes).to include('fill="url(#g)"')
      expect(bytes).to include('<use href="#g"/>')
    end

    [
      [ "a script", "<script>alert(1)</script>" ],
      [ "an event handler", '<rect width="1" height="1" onclick="alert(1)"/>' ],
      [ "an external image", '<image href="https://tracker.example.test/pixel.png" width="1" height="1"/>' ],
      [ "an external reference", '<use href="https://example.test/sprite.svg#a"/>' ],
      [ "a javascript link", '<a href="javascript:alert(1)"><rect width="1" height="1"/></a>' ],
      [ "embedded HTML", '<foreignObject><div xmlns="http://www.w3.org/1999/xhtml">Hi</div></foreignObject>' ],
      [ "an external stylesheet", "<style>@import url(https://example.test/a.css);</style>" ],
      [ "an external fill", '<rect width="1" height="1" fill="url(https://example.test/a.svg#x)"/>' ]
    ].each do |label, markup|
      it "refuses #{label}" do
        expect { clean(svg_logo(markup)) }.to raise_error(described_class::InvalidLogo)
      end
    end

    it "refuses entities, DOCTYPEs and files without a size" do
      entity = %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">&x;</svg>)
      expect { clean(entity) }.to raise_error(described_class::InvalidLogo, /DOCTYPE/)
      expect { clean('<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>') }.to raise_error(described_class::InvalidLogo, /viewBox/)
      expect { clean("<svg><rect/></svg>") }.to raise_error(described_class::InvalidLogo, /isn't an SVG/)
    end
  end

  it "refuses other types, empty files and files over 1 MB" do
    expect { clean("\xFF\xD8\xFF\xE0jpeg".b) }.to raise_error(described_class::InvalidLogo, /PNG, SVG or WebP/)
    expect { clean("GIF89a".b) }.to raise_error(described_class::InvalidLogo, /PNG, SVG or WebP/)
    expect { clean("") }.to raise_error(described_class::InvalidLogo, /empty/)
    expect { clean(png_logo + ("\x00".b * 1.megabyte)) }.to raise_error(described_class::InvalidLogo, /1 MB/)
  end
end
