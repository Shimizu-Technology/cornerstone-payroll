# frozen_string_literal: true

# Shared footer rendering for PDF generators.
#
# Prawn's `repeat(:all, dynamic: true)` + `canvas` positions the footer
# perfectly in the page margin (never overlapping content), but creates
# one blank trailing page as a side-effect. This module renders the footer
# and then strips that extra page before returning the final PDF bytes.
module PdfFooter
  private

  # Render a canvas-positioned footer on every page and return rendered bytes
  # with the blank trailing page removed.
  #
  # Call this INSTEAD of pdf.render — it sets up the footer, renders, and strips.
  #
  # @param pdf [Prawn::Document]
  # @param text [String] the footer text
  # @param font_size [Numeric] footer font size (default 6)
  # @return [String] the final PDF bytes
  def render_with_footer(pdf, text, font_size: 6, height: 16)
    pdf.repeat(:all, dynamic: true) do
      pdf.canvas do
        left = pdf.page.margins[:left]
        right = pdf.page.margins[:right]
        width = pdf.bounds.width - left - right
        pdf.bounding_box([ left, 26 ], width: width, height: height) do
          pdf.stroke_color "CCCCCC"
          pdf.stroke_horizontal_rule
          pdf.move_down 3
          pdf.fill_color "666666"
          pdf.font_size(font_size) do
            pdf.text(text, align: :center)
          end
          pdf.fill_color "1A1A2E"
        end
      end
    end

    strip_trailing_blank_page(pdf.render, footer_text: text)
  end

  def strip_trailing_blank_page(raw_pdf, footer_text:)
    require "combine_pdf"
    require "pdf/reader"

    reader = PDF::Reader.new(StringIO.new(raw_pdf))
    return raw_pdf if reader.pages.length <= 1

    expected_footer_text = normalized_pdf_text(footer_text)
    actual_last_page_text = normalized_pdf_text(reader.pages.last.text)

    return raw_pdf unless actual_last_page_text == expected_footer_text

    parsed = CombinePDF.parse(raw_pdf)
    return raw_pdf if parsed.pages.length <= 1

    parsed.remove(parsed.pages.length - 1)
    parsed.to_pdf
  end

  def normalized_pdf_text(text)
    text.to_s.lines.map(&:strip).reject(&:blank?).join("\n")
  end
end
