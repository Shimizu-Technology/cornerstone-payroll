# frozen_string_literal: true

# Prawn 2.4 tries each fallback even for line breaks and other missing
# glyphs. Keep the CJK font out of that search until a CJK character needs it.
module PayrollCjkFallback
  private

  def find_font_for_this_glyph(char, current_font, fallback_fonts)
    if fallback_fonts.include?(PdfUnicodeFont::CJK_FAMILY) && !PdfUnicodeFont.cjk_character?(char)
      fallback_fonts.delete(PdfUnicodeFont::CJK_FAMILY)
    end
    super
  end
end

Prawn::Text::Formatted::Box.prepend(PayrollCjkFallback)
