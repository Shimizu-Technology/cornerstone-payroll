# frozen_string_literal: true

require "combine_pdf"
require "prawn"
require "csv"

# Applied only to downloads for calculated/approved native payroll.
class PayrollReportPreview
  LABEL = "PREVIEW, payroll not yet committed"

  def self.pdf(bytes)
    document = CombinePDF.parse(bytes)
    document.pages.each do |page|
      box = page[:MediaBox] || [ 0, 0, 612, 792 ]
      width = box[2] - box[0]
      height = box[3] - box[1]
      header = Prawn::Document.new(page_size: [ width, height ], margin: 0)
      header.text_box LABEL, at: [ 8, height - 2 ], width: width - 16, height: 12, size: 8, align: :center
      page << CombinePDF.parse(header.render).pages.first
    end
    document.to_pdf
  end

  def self.csv(bytes)
    CSV.generate_line([ LABEL ]) + bytes
  end
end
