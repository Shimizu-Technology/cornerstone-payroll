# frozen_string_literal: true

class Form1096TotalsPdfGenerator
  def initialize(company:, file:, draft:)
    @company, @file, @draft = company, file, draft
  end

  def generate
    records = @file.scan(/.{748}\r\n/m)
    totals = records.find { |r| r.start_with?("C") }
    PdfUnicodeFont.document.tap do |pdf|
      pdf.text "#{@draft ? 'DRAFT - ' : ''}1096 totals (for your records)", size: 18
      pdf.move_down 16
      pdf.text "For your records - not for filing", style: :bold
      pdf.move_down 16
      pdf.text @company.name
      pdf.text "EIN: #{@company.ein}"
      pdf.text @company.full_address
      pdf.move_down 16
      pdf.text "Tax year: 2026 | Form: 1099-NEC"
      pdf.text "Total forms: #{totals[1, 8].to_i}"
      pdf.text "Box 1 nonemployee compensation: $#{format('%.2f', totals[15, 18].to_i / 100.0)}"
      pdf.text "Box 4 federal income tax withheld: $#{format('%.2f', totals[69, 18].to_i / 100.0)}"
      pdf.move_down 16
      pdf.text "These totals match the GuamTax e-file. Keep this sheet with your records."
    end.render
  end
end
