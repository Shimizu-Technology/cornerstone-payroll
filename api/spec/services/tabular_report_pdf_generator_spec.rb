# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe TabularReportPdfGenerator do
  it "renders every normalized sheet into a readable multi-page PDF" do
    generator = described_class.new(
      title: "Payroll Summary by Period",
      subtitle: "Reports Co — January 1 through January 31, 2026",
      filename: "payroll-summary.pdf",
      sheets: [
        {
          name: "Employee Summary",
          rows: [
            [ "Employee", "Gross Pay", "Net Pay" ],
            [ "Ana Perez", BigDecimal("1250.50"), BigDecimal("975.25") ]
          ]
        },
        {
          name: "Payroll Fields",
          rows: [
            [ "Employee", "Field", "Amount" ],
            [ "Ana Perez", "Certification Pay", BigDecimal("50.00") ]
          ]
        }
      ]
    )

    pdf = generator.generate
    reader = PDF::Reader.new(StringIO.new(pdf))
    text = reader.pages.map(&:text).join("\n")

    expect(generator.filename).to eq("payroll-summary.pdf")
    expect(pdf).to start_with("%PDF")
    expect(reader.page_count).to eq(2)
    expect(text).to include("Payroll Summary by Period")
    expect(text).to include("Ana Perez")
    expect(text).to include("1250.50")
    expect(text).to include("Payroll Fields")
    expect(text).to include("Certification Pay")
  end
end
