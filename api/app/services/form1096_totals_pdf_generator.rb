# frozen_string_literal: true

class Form1096TotalsPdfGenerator
  # Either the Pub 1220 file or payee totals (forms, box1_cents, box4_cents).
  # A demo company has no e-file, so its totals come from the payees directly.
  def initialize(company:, draft:, file: nil, totals: nil)
    @company, @file, @totals, @draft = company, file, totals, draft
  end

  def generate
    forms, box1, box4 = if @totals
      @totals.values_at(:forms, :box1_cents, :box4_cents)
    else
      record = @file.scan(/.{748}\r\n/m).find { |r| r.start_with?("C") }
      [ record[1, 8].to_i, record[15, 18].to_i, record[69, 18].to_i ]
    end
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
      pdf.text "Total forms: #{forms}"
      pdf.text "Box 1 nonemployee compensation: $#{money(box1)}"
      pdf.text "Box 4 federal income tax withheld: $#{money(box4)}"
      pdf.move_down 16
      # A client without an e-file gets the records-only footer.
      pdf.text @company.demo? ? "Keep this sheet with your records." : "These totals match the GuamTax e-file. Keep this sheet with your records."
      DemoPdfFooter.draw_prawn_footer(pdf, company: @company)
    end.render
  end
  private

  def money(cents)
    dollars, remainder = cents.divmod(100)
    "#{dollars.to_s.reverse.scan(/.{1,3}/).join(',').reverse}.#{remainder.to_s.rjust(2, '0')}"
  end
end
