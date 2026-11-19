# frozen_string_literal: true

# Draw in the generator's document so every page retains its font/transparency
# resources when PDFs are combined. Does not move or cover any payroll content.
class PdfPreviewWatermark
  def self.apply(pdf, label: "PREVIEW")
    pdf.page_count.times do |index|
      pdf.go_to_page(index + 1)
      draw_page(pdf, label: label)
    end
  end

  # Marks only the page being drawn, for generators that build page by page.
  # The note is the small line across the top; it defaults to the label.
  # bands splits the page into equal horizontal strips, one mark in each, for
  # pages that hold more than one form.
  def self.draw_page(pdf, label: "PREVIEW", note: label, bands: 1)
    pdf.canvas do
      width = pdf.bounds.width
      height = pdf.bounds.height
      pdf.save_graphics_state do
        pdf.fill_color "C00000"
        pdf.transparent(0.18) do
          bands.times do |index|
            center = height * (bands - index - 0.5) / bands
            pdf.rotate(35, origin: [ width / 2, center ]) do
              pdf.text_box label, at: [ 0, center + 65 ], width: width, height: 140,
                size: 100, style: :bold, align: :center
            end
          end
        end
        pdf.text_box note, at: [ 18, height - 6 ], width: width - 36, height: 12,
          size: 8, style: :bold, align: :center
      end
    end
  end
end
