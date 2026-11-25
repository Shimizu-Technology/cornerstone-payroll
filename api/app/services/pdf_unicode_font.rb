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
  CJK_FAMILY = "PayrollCJK"
  CJK_FILE = Rails.root.join("vendor/fonts/cjk/PayrollCJK-Regular.ttf").to_s
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

  class CjkTTF < Prawn::Fonts::TTF
    private

    # Prawn 2.4 writes supplementary characters as five-digit code points.
    # PDF ToUnicode maps require UTF-16BE, including both surrogate units.
    def embed(reference, subset)
      super
      map = subsets[subset].to_unicode_map
      return unless map.values.any? { |codepoint| codepoint > 0xFFFF }

      blocks = map.sort.each_slice(100).map do |entries|
        lines = entries.map do |code, codepoint|
          format("<%02x><%s>", code, codepoint.chr(Encoding::UTF_16BE).unpack1("H*"))
        end
        [ "#{lines.length} beginbfchar", *lines, "endbfchar" ].join("\n")
      end
      stream = PDF::Core::Stream.new
      stream << (UNICODE_CMAP_TEMPLATE % blocks.join("\n"))
      stream.compress!
      reference.data.fetch(:ToUnicode).stream = stream
    end
  end

  # Prawn's positioned draw_text does not use the formatted-text fallback.
  # Split only when needed so existing primary-font positioning stays intact.
  module CjkText
    def find_font(name, options = {})
      return super unless name == PdfUnicodeFont::CJK_FAMILY

      file = PdfUnicodeFont::CJK_FILE
      font_registry["#{file}:0"] ||= CjkTTF.new(self, file, family: name)
    end

    def draw_text(text, options)
      return super if text.to_s.ascii_only? || options[:at].nil?

      font_options = options.slice(:style)
      primary = font
      font(primary.family, font_options) { primary = font } if options[:style]
      runs = cjk_runs(text.to_s, primary)
      return super unless runs.any?(&:first)

      x, y = options.fetch(:at)
      draw_options = options.except(:rotate, :style)
      draw = lambda do
        runs.each do |cjk, chars|
          run = chars.join
          run_options = draw_options.merge(at: [ x, y ])
          width_options = draw_options.slice(:size, :kerning)
          if cjk
            font(PdfUnicodeFont::CJK_FAMILY) do
              super(run, run_options)
              x += width_of(run, **width_options)
            end
          else
            super(run, run_options.merge(font_options))
            x += primary.compute_width_of(run, **width_options.reverse_merge(size: font_size))
          end
        end
      end
      return draw.call unless options[:rotate]

      rotate(options[:rotate], origin: [ x, y ], &draw)
    end

    private

    def width_of_string(string, options = {})
      return super if string.ascii_only?

      runs = cjk_runs(string, font)
      return super unless runs.any?(&:first)

      runs.sum do |cjk, chars|
        if cjk
          width = nil
          font(PdfUnicodeFont::CJK_FAMILY) { width = super(chars.join, options.except(:style)) }
          width
        else
          super(chars.join, options)
        end
      end
    end

    def cjk_runs(text, primary)
      text.each_char.chunk { |char| PdfUnicodeFont.cjk_codepoints.include?(char.ord) && !primary.glyph_present?(char) }.to_a
    end
  end

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
    pdf.fallback_fonts = [ *pdf.fallback_fonts, CJK_FAMILY ]
    pdf.extend(CjkText)
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
    @printable_codepoints ||= (codepoints_for(FILES[:normal]) | cjk_codepoints).freeze
  end

  def cjk_codepoints
    @cjk_codepoints ||= codepoints_for(CJK_FILE).freeze
  end

  def codepoints_for(file)
    TTFunk::File.open(file).cmap.unicode.max_by { |table| table.code_map.size }.code_map
      .select { |_code, glyph| glyph.positive? }.keys.to_set.freeze
  end
end
