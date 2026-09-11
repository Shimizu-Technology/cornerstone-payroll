require "rails_helper"
require "caxlsx"

RSpec.describe "MoSa per-payroll bonus import" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, first_name: "Sample", last_name: "Doctor", employment_type: "salary", salary_type: "per_period", pay_rate: 1000) }
  let(:period) { create(:pay_period, company: company) }
  let(:service) { PayrollImport::ImportService.new(period) }

  def workbook_rows(values)
    file = Tempfile.new([ "bonus-test", ".xlsx" ])
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "BONUSES") do |sheet|
      3.times { sheet.add_row([ "Header" ]) }
      sheet.add_row([ nil, nil, "Last Name", "First Name", nil, "Bonus" ])
      values.each { |last_name, first_name, value| sheet.add_row([ nil, nil, last_name, first_name, nil, value ]) }
    end
    package.serialize(file.path)
    PayrollImport::LoanTipExcelParser.parse(file.path)
  ensure
    file&.unlink
  end

  it "parses explicit money and zero but leaves missing amounts absent" do
    rows = workbook_rows([ [ "Doctor", "Sample", 150.25 ], [ "Clear", "Sample", 0 ], [ "Absent", "Sample", nil ] ])
    expect(rows.map { |row| row[:bonus] }).to eq([ 150.25, 0 ])
  end

  it "rejects malformed and duplicate bonus rows" do
    expect { workbook_rows([ [ "Doctor", "Sample", "tbd" ] ]) }.to raise_error(ArgumentError, /BONUSES row 5/)
    expect { workbook_rows([ [ "Doctor", "Sample", 50 ], [ "Doctor", "Sample", 75 ] ]) }.to raise_error(ArgumentError, /Duplicate bonus/)
  end

  it "previews and calculates a workbook bonus, then protects a manually cleared bonus on reimport" do
    employee
    rows = workbook_rows([ [ "Doctor", "Sample", 150 ] ])
    preview = service.preview(excel_records: rows, pdf_records: [])
    expect(preview[:can_apply]).to be(true)
    expect(preview[:matched].first).to include(bonus: 150, effective_bonus: 150, bonus_keeps_manual: false)
    expect(service.apply!(matched: preview[:matched])[:errors]).to be_empty
    item = period.payroll_items.find_by!(employee: employee)
    expect(item.gross_pay).to eq(1150)
    expect(item.bonus).to eq(150)

    PayrollBonusInput.manual!(item, 0)
    item.calculate!
    rows = workbook_rows([ [ "Doctor", "Sample", 275 ] ])
    second = service.preview(excel_records: rows, pdf_records: [])
    expect(second[:matched].first).to include(bonus: 275, effective_bonus: 0, bonus_keeps_manual: true)
    expect(service.apply!(matched: second[:matched])[:errors]).to be_empty
    expect(item.reload.gross_pay).to eq(1000)
    expect(item.imported_bonus).to eq(275)
  end
end
