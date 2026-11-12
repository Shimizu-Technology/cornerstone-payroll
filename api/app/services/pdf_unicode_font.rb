# frozen_string_literal: true

# Every generated PDF uses an embedded Unicode TrueType font. Prawn's built-in
# Helvetica only encodes Windows-1252, so one name like "Wiśniewska" raised
# Prawn::Errors::IncompatibleStringEncoding and failed the whole document.
#
# Liberation Sans has Helvetica's character widths. Its vertical metrics are
# pinned to Helvetica's below, so line heights and baselines also match and
# layouts measured against Helvetica (checks, stubs, official-form overlays)
# keep their fit. The Helvetica family names are remapped too, so generators
# that select "Helvetica" or "Helvetica-Bold" explicitly get the same font.
module PdfUnicodeFont
  FAMILY = "LiberationSans"
  FONT_DIR = Rails.root.join("vendor/fonts/liberation-sans")
  FILES = {
    normal: FONT_DIR.join("LiberationSans-Regular.ttf").to_s,
    bold: FONT_DIR.join("LiberationSans-Bold.ttf").to_s,
    italic: FONT_DIR.join("LiberationSans-Italic.ttf").to_s,
    bold_italic: FONT_DIR.join("LiberationSans-BoldItalic.ttf").to_s
  }.freeze

  # Helvetica AFM metrics per 1000 em: Ascender 718, Descender -207, and the
  # FontBBox height minus both (Prawn's AFM line gap): 1156 regular, 1190 bold.
  HELVETICA_ASCENDER = 718
  HELVETICA_DESCENDER = -207
  HELVETICA_LINE_GAP = { normal: 231, italic: 231, bold: 265, bold_italic: 265 }.freeze

  class HelveticaMetricsTTF < Prawn::Fonts::TTF
    def initialize(document, name, options = {})
      style = options.fetch(:style)
      super(document, name, options.except(:style))
      @ascender = HELVETICA_ASCENDER
      @descender = HELVETICA_DESCENDER
      @line_gap = HELVETICA_LINE_GAP.fetch(style)
    end
  end

  # Liberation Sans has no CJK or Hangul glyphs, so those characters print as
  # empty boxes. Checks and tax filings refuse such a name instead of issuing
  # a document whose payee or employee can't be read.
  class UnprintableName < StandardError
    def initialize(label, name, characters)
      super("#{label} \"#{name.to_s.squish}\" has characters checks and tax forms can't print " \
            "(#{characters.map { |char| visible(char) }.join(' ')}). Change it to Latin letters, then try again.")
    end

    private

    # Invisible characters are named by code point so the operator can find them.
    def visible(char)
      char.match?(/[\p{L}\p{M}\p{N}\p{P}\p{S}]/) ? char : format("U+%04X", char.ord)
    end
  end

  module_function

  # Drop-in for Prawn::Document.new. Block forms receive the document.
  def document(**options, &block)
    pdf = apply!(Prawn::Document.new(**options))
    block&.call(pdf)
    pdf
  end

  def apply!(pdf)
    # Prawn names each font from the registry size when it is built, so each
    # one is registered before the next is created to keep the names unique.
    styles = FILES.to_h do |style, file|
      font = HelveticaMetricsTTF.new(pdf, file, family: FAMILY, style: style)
      pdf.font_registry["#{file}:0"] = font
      [ style, font ]
    end
    pdf.font_families.update(
      FAMILY => styles,
      "Helvetica" => styles,
      "Helvetica-Bold" => styles.merge(normal: styles[:bold], italic: styles[:bold_italic]),
      "Helvetica-Oblique" => styles.merge(normal: styles[:italic], bold: styles[:bold_italic]),
      "Helvetica-BoldOblique" => styles.transform_values { styles[:bold_italic] }
    )
    pdf.font(FAMILY)
    pdf
  end

  # Multi-line values are checked line by line, since line breaks are layout
  # rather than glyphs. Any other character without a glyph, including a tab,
  # prints as a box.
  def unprintable_characters(text)
    text.to_s.each_line.flat_map { |line| line.chomp.each_char.to_a }
      .reject { |char| char == " " || printable_codepoints.include?(char.ord) }.uniq
  end

  def ensure_printable!(name, label:)
    missing = unprintable_characters(name)
    raise UnprintableName.new(label, name, missing) if missing.any?
  end

  def printable_codepoints
    # Glyph 0 is the .notdef box, so a code mapped to it can't print either.
    @printable_codepoints ||= TTFunk::File.open(FILES[:normal]).cmap.unicode.first.code_map
      .select { |_code, glyph| glyph.positive? }.keys.to_set.freeze
  end
end
