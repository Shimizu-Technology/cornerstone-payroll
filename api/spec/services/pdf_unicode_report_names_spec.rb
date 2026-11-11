# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Report and filing PDFs with accented and non-Latin names" do
  let(:full_names) { UnicodePdfNames::WORKERS.map { |worker| "#{worker[:first_name]} #{worker[:last_name]}" } }

  it "prints the tabular summary and annual reports (client Payroll Summary PDF)" do
    rows = [ [ "Employee", "Gross Pay", "Net Pay" ] ] + full_names.map { |name| [ name, BigDecimal("1200.00"), BigDecimal("1000.00") ] }
    pdf = TabularReportPdfGenerator.new(
      title: "Payroll Summary by Pay Date",
      subtitle: "Hagåtña Café — March 2026",
      filename: "payroll_summary.pdf",
      sheets: [ { name: "Employee Summary", rows: rows } ]
    ).generate

    expect(unicode_pdf_text(pdf)).to include("Hagåtña Café", *UnicodePdfNames::TOKENS)
  end

  it "prints the 1099-NEC preparation summary" do
    contractors = full_names.each_with_index.map do |name, index|
      { name: name, business_name: index.zero? ? "Wiśniewska Budownictwo Sp. z o.o." : nil, tin_type: "SSN",
        tin_last_four: "12#{index}4", payment_count: 2, total_compensation: 900.0 + index, federal_withheld: 0.0,
        w9_on_file: index.even?, compliance_issues: index.even? ? [] : [ "Missing W-9" ] }
    end
    report = {
      meta: { year: 2026, contractor_count: contractors.size, reportable_count: contractors.size, filing_threshold: 600,
        caveats: [ "Preparation summary only." ] },
      payer: { name: "Mañibusan Café LLC", ein: "98-7654321", address: "1 Chalan Santo Papa", city_state_zip: "Hagåtña, GU 96910" },
      totals: { total_compensation: 7228.0, reportable_compensation: 7228.0, total_federal_withheld: 0.0 },
      reportable_contractors: contractors
    }

    text = unicode_pdf_text(Form1099NecPdfGenerator.new(report).generate)
    expect(text).to include("Mañibusan Café LLC", "Budownictwo", *UnicodePdfNames::TOKENS)
  end

  it "prints the quarterly compliance packet, including the SW-2 employee rows" do
    company = create(:company, name: "Hagåtña Café Mañibusan", city: "Hagåtña", state: "GU", zip: "96910")
    department = create(:department, company: company)
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14), pay_date: Date.new(2026, 4, 17))
    UnicodePdfNames::WORKERS.first(4).each do |worker|
      employee = create(:employee, company: company, department: department, first_name: worker[:first_name],
        last_name: worker[:last_name], ssn_encrypted: "123-45-#{rand(1000..9999)}")
      create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 1000, net_pay: 800,
        withholding_tax: 50, social_security_tax: 62, employer_social_security_tax: 62, medicare_tax: 14.5,
        employer_medicare_tax: 14.5)
    end

    report = QuarterlyCompliancePacketBuilder.new(company, 2026, 2).generate
    text = unicode_pdf_text(QuarterlyCompliancePacketPdfGenerator.new(report).generate)

    expect(text).to include("Hagåtña Café Mañibusan")
    expect(text).to include("Wiśniewska").or include("WIŚNIEWSKA")
    expect(text).to include("Nguyễn").or include("NGUYỄN")
  end
end
