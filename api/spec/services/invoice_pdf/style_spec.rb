# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoicePdf::Style do
  it "defaults each theme to its own accent and records the resolved color" do
    expect(described_class::THEMES.map { |theme| described_class.new(theme: theme).accent_hex })
      .to eq(%w[#1F4E79 #0F766E #6B2737 #1E40AF])
    expect(described_class.new(theme: "modern", accent_color: "#7c2d12").to_snapshot).to include(
      "theme" => "modern", "accent_color" => "#7C2D12", "logo_size" => "medium", "show_item_column" => true
    )
  end

  it "treats a snapshot without a style as legacy and an unknown theme as Classic" do
    expect(described_class.from_snapshot({ "invoice" => {} })).to be_legacy
    expect(described_class.from_snapshot({ "style" => nil })).to be_legacy
    expect(described_class.from_snapshot({ "style" => { "theme" => "neon" } }).theme).to eq("classic")
    expect(described_class.legacy.to_snapshot).to be_nil
  end

  it "reads every recorded switch back from a snapshot" do
    style = described_class.new(theme: "banner", accent_color: "#334155", logo_size: "large", show_service_period: false,
                                show_item_column: false, show_how_to_pay: false)
    restored = described_class.from_snapshot({ "style" => style.to_snapshot })

    expect(restored.to_snapshot).to eq(style.to_snapshot)
  end

  describe "contrast" do
    it "puts white text on dark accents and black text on light ones" do
      expect(described_class.new(theme: "classic").on_accent).to eq("FFFFFF")
      expect(described_class.new(theme: "classic", accent_color: "#FDE047").on_accent).to eq("000000")
      expect(described_class.new(theme: "classic", accent_color: "#FFFFFF").on_accent).to eq("000000")
    end

    it "keeps text on any accent, and the accent as text on paper, at 4.5:1 or better" do
      colors = %w[#000000 #FFFFFF #FDE047 #A3E635 #22D3EE #F472B6 #808080 #777777 #767676 #0F766E] +
               Array.new(400) { |index| format("#%06X", (index * 2_654_435_761) % 0x1000000) }
      colors.each do |color|
        style = described_class.new(theme: "classic", accent_color: color)

        expect(described_class.contrast_ratio(style.accent, style.on_accent)).to be >= 4.5, color
        expect(described_class.contrast_ratio(style.accent_text, "FFFFFF")).to be >= 4.5, color
      end
    end

    it "leaves an accent that already reads on white unchanged" do
      expect(described_class.new(theme: "classic").accent_text).to eq("1F4E79")
    end
  end
end
