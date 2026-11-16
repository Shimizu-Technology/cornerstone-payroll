# frozen_string_literal: true

# Draw in the generator's document so every page retains its font/transparency
# resources when PDFs are combined. Does not move or cover any payroll content.
class PdfPreviewWatermark
  def self.apply(pdf)
    pdf.page_count.times do |index|
      pdf.go_to_page(index + 1)
      pdf.canvas do
        width = pdf.bounds.width
        height = pdf.bounds.height
        pdf.save_graphics_state do
          pdf.fill_color "C00000"
          pdf.transparent(0.18) do
            pdf.rotate(35, origin: [ width / 2, height / 2 ]) do
              pdf.text_box "PREVIEW", at: [ 0, height / 2 + 65 ], width: width, height: 140,
                size: 100, style: :bold, align: :center
            end
          end
          pdf.text_box "PREVIEW", at: [ 18, height - 6 ], width: width - 36, height: 12,
            size: 8, style: :bold, align: :center
        end
      end
    end
  end
end
