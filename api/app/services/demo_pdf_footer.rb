# frozen_string_literal: true

# Shared D-3 footer notice for PDFs generated for demo companies.
# Shown ONLY when demo is true; real client PDFs never render this line.
module DemoPdfFooter
  TEXT = "Demo company. Not a real payroll record."
  TEXT_COLOR = "666666"

  module_function

  def demo?(company: nil, demo: nil)
    return demo == true unless demo.nil?

    company&.demo? == true
  end

  def append(base_text, company: nil, demo: nil)
    return base_text unless demo?(company: company, demo: demo)

    text = base_text.to_s
    return TEXT if text.blank?
    return text if text.include?(TEXT)

    "#{text}\n#{TEXT}"
  end

  # Draws the demo footer centered in the bottom margin of every page on a
  # Prawn document (used by generators that do not go through PdfFooter).
  # Default y: 26 (box 16..26pt, baseline ~19.5pt) stays above printers' ~12pt
  # unprintable margin and well inside >=36pt report bottom margins.
  def draw_prawn_footer(pdf, company: nil, demo: nil, y: 26, height: 10, font_size: 6.5)
    return unless demo?(company: company, demo: demo)

    pdf.repeat(:all) do
      pdf.canvas do
        left = pdf.page.margins[:left]
        right = pdf.page.margins[:right]
        width = pdf.bounds.width - left - right
        pdf.save_graphics_state do
          pdf.fill_color TEXT_COLOR
          pdf.text_box(
            TEXT,
            at: [ left, y ],
            width: width,
            height: height,
            size: font_size,
            align: :center,
            valign: :center
          )
        end
      end
    end
  end

  # Draws the demo footer centered in the bottom margin of the current page on
  # an OfficialPdfOverlay or fixed-coordinate Prawn document (e.g. W-2GU, 1099,
  # W-3SS, Form 500, quarterly compliance forms). Default y: 26 (baseline ~19.5pt)
  # clears printers' ~12pt unprintable margin; dense official overlays like SW-2
  # may pass a lower y explicitly.
  def draw_overlay_footer(pdf, company: nil, demo: nil, y: 26, height: 10, font_size: 6.5, margin_x: 18)
    return unless demo?(company: company, demo: demo)

    pdf.save_graphics_state do
      pdf.fill_color TEXT_COLOR
      pdf.text_box(
        TEXT,
        at: [ margin_x, y ],
        width: pdf.bounds.width - (margin_x * 2),
        height: height,
        size: font_size,
        align: :center,
        valign: :center
      )
    end
  end

  # Draws the demo footer inside a check-stock stub section, strictly clear of
  # the check face, MICR band, perforation, and printer unprintable margin on
  # both top_check and bottom_check layouts. Placed at stub_bottom + 16..26pt
  # (baseline ~19pt), well below stub content (which ends ~52pt above stub_bottom)
  # and >=14pt clear of both section edges regardless of printer alignment offset.
  def draw_check_stub_footer(pdf, stub_bottom:, page_width:, margin_x:, company: nil, demo: nil)
    return unless demo?(company: company, demo: demo)

    pdf.save_graphics_state do
      pdf.fill_color TEXT_COLOR
      pdf.text_box(
        TEXT,
        at: [ margin_x, stub_bottom + 26.0 ],
        width: page_width - (margin_x * 2),
        height: 10.0,
        size: 6.0,
        align: :center,
        valign: :center
      )
    end
  end
end
