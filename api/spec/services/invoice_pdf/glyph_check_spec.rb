# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoicePdf::GlyphCheck do
  def snapshot(recipient_name:, description: "Accounting Services")
    { "invoice" => { "invoice_number" => "7055" }, "billing_profile" => { "name" => "Marianas Bay CPA" },
      "recipient" => { "name" => recipient_name }, "line_items" => [ { "item_name" => "Consulting", "description" => description } ] }
  end

  # Glyph ids straight from the TrueType cmap tables of every font the PDFs
  # embed. Glyph 0 (or no mapping) is the .notdef box.
  def glyph_ids(char)
    Dir[Rails.root.join("vendor/fonts/**/*.ttf")].to_h do |path|
      [ File.basename(path), TTFunk::File.open(path).cmap.unicode.first[char.ord].to_i ]
    end
  end

  it "accepts Chamorro and other Latin names, which every fallback face covers" do
    expect(described_class.problems(snapshot(recipient_name: "Hagåtña Muñoz Nguyễn Wiśniewska"))).to eq([])
    "åñễś".each_char do |char|
      liberation = glyph_ids(char).select { |file, _id| file.start_with?("LiberationSans") }
      expect(liberation.size).to eq(4)
      expect(liberation.values).to all(be_positive), char
    end
  end

  it "accepts CJK and flags emoji and tabs with the field they are in" do
    problems = described_class.problems(snapshot(recipient_name: "Hagåtña Muñoz 東京 😀", description: "Fee\tdue"))

    expect(problems).to eq([
      { "field" => "Customer name", "characters" => [ "😀" ] },
      { "field" => "Line 1 description", "characters" => [ "U+0009" ] }
    ])
    expect(described_class.message(problems)).to include("Customer name (😀)", "Line 1 description (U+0009)",
                                                         "empty boxes", "Replace them")
  end

  it "flags only characters that no embedded font can draw" do
    %w[😀 🦄].each do |char|
      expect(glyph_ids(char).values).to all(eq(0)), "#{char} has a glyph in #{glyph_ids(char).select { |_f, id| id.positive? }.keys}"
    end
  end
end
