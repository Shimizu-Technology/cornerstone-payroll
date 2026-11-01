# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"
require "roo"

RSpec.describe "Payroll register saved-paycheck reconciliation", type: :request do
  let(:company) { create(:company, simple_payroll_register_enabled: true) }
  let(:period) { create(:pay_period, :committed, company: company, start_date: Date.new(2026, 10, 19), end_date: Date.new(2026, 11, 1), pay_date: Date.new(2026, 11, 5)) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let!(:items) do
    [ [ "Roth Rate", 960, 28.80, 0, 0 ], [ "Roth Catchup", 2000, 1216.35, 0, 0 ],
      [ "Field Retirement", 2000, 0, 927.91, 0 ], [ "Reimbursement", 2000, 0, 0, 20 ], [ "Ordinary", 2000, 0, 0, 0 ] ].map do |name, gross, roth, field, other|
      employee = create(:employee, company: company, first_name: name, last_name: "Employee", roth_retirement_rate: name == "Roth Rate" ? 0.03 : 0)
      ss = (gross.to_d * 0.062).round(2)
      medicare = (gross.to_d * 0.0145).round(2)
      deductions = 100.to_d + ss + medicare + roth.to_d + field.to_d
      item = create(:payroll_item, employee: employee, pay_period: period, pay_rate: gross.to_d / 80, hours_worked: 80,
        gross_pay: gross, non_taxable_pay: other, withholding_tax: 100, social_security_tax: ss, medicare_tax: medicare,
        roth_retirement_payment: roth, total_deductions: deductions, net_pay: gross.to_d + other.to_d - deductions)
      if name == "Roth Catchup"
        item.update_columns(ytd_retirement: 24_500, retirement_rule_snapshot: { "roth_catch_up_required" => true, "ytd_before" => { "retirement" => "24500.0" } })
      end
      if field.positive?
        definition = create(:payroll_field_definition, company: company, name: "401(k) Pre-Tax", kind: "deduction",
          tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax")
        entry = create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: definition, amount: field, reporting_group: "401k_pre_tax")
        type = DeductionType.create!(company: company, name: "Payroll Field: 401(k) Pre-Tax", category: "pre_tax", sub_category: "retirement", reporting_group: "401k_pre_tax")
        deduction = item.payroll_item_deductions.create!(deduction_type: type, label: definition.name, category: "pre_tax", reporting_group: "401k_pre_tax", amount: field)
        PayrollComponentMirrors.record!(entry, deduction)
        entry.save!
        match = DeductionType.create!(company: company, name: "401(k) Employer Match", category: "employer_contribution", sub_category: "retirement", reporting_group: "401k_pre_tax")
        item.payroll_item_deductions.create!(deduction_type: match, label: match.name, category: "employer_contribution", amount: 100, reporting_group: "401k_pre_tax")
      end
      item
    end
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(actor)
  end

  def register
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("report").deep_symbolize_keys
  end

  def workbook
    file = Tempfile.new([ "register-reconciliation", ".xlsx" ])
    file.binmode
    file.write(response.body)
    file.flush
    yield Roo::Excelx.new(file.path)
  ensure
    file&.close!
  end

  def assert_reconciles(gross:, other:, deductions:, net:)
    expect((gross.to_d + other.to_d - deductions.to_d).round(2)).to eq(net.to_d.round(2))
  end

  it "uses the stub retirement source once, retains raw snapshots, and reconciles screen data" do
    report = register
    expect(report[:register_review]).to be_empty
    report[:employees].each do |row|
      item = items.find { |candidate| candidate.employee_id == row[:employee_id] }
      canonical = PayrollRetirementTotals.for_item(item.reload, for_reporting: true)
      expect(row[:traditional_retirement_total].to_d).to eq(canonical[:retirement])
      expect(row[:roth_retirement_total].to_d).to eq(canonical[:roth_retirement])
      expect(row[:retirement_payment].to_d).to eq(item.retirement_payment)
      assert_reconciles(gross: row[:gross_pay], other: row[:non_taxable_additions_total], deductions: row[:total_deductions], net: row[:net_pay])
    end
    expect(report[:summary][:total_traditional_retirement].to_d).to eq(927.91.to_d)
    expect(report[:summary][:total_roth_retirement].to_d).to eq(1245.15.to_d)
    expect(report[:summary][:total_retirement].to_d).to eq(2173.06.to_d)
    expect(report[:summary][:total_employer_contributions].to_d).to eq(100.to_d)
    expect(report[:simple_register][:rows].find { |row| row[:employee] == "Reimbursement Employee" }[:non_taxable_additions]).to eq(20)
  end

  it "reads reconciling PDF worker rows and matching retirement totals from emitted PDF bytes" do
    report = register
    get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include("Non-Taxable", "Pre-Tax Retirement", "Roth Retirement")
    monetary_keys = PayrollRegisterPdfGenerator.new(report).send(:employee_table_columns).map { |column| column[:key] } - %i[employee_name employment_type hours_worked overtime_hours check_number]
    report[:employees].each do |row|
      amounts = text.lines.select { |line| line.lstrip.start_with?(row[:employee_name]) }.flat_map { |line| line.scan(/\$(-?[\d,]+\.\d{2})/).flatten }.first(monetary_keys.length)
      actual = monetary_keys.zip(amounts.map { |value| value.delete(",").to_d }).to_h
      expect(actual[:retirement_payment]).to eq(row[:traditional_retirement_total].to_d)
      expect(actual[:roth_retirement_payment]).to eq(row[:roth_retirement_total].to_d)
      assert_reconciles(gross: actual[:gross_pay], other: actual[:non_taxable_additions_total], deductions: actual[:total_deductions], net: actual[:net_pay])
    end
    totals = text.lines.select { |line| line.lstrip.start_with?("TOTALS") }.join(" ")
    expect(totals).to include("$927.91", "$1245.15")
  end

  it "exports reconciling XLSX detail and simple-register rows" do
    get "/api/v1/admin/reports/payroll_register_xlsx", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    workbook do |book|
      sheet = book.sheet("Employees")
      headers = sheet.row(4)
      (5..9).each do |number|
        row = headers.zip(sheet.row(number)).to_h
        assert_reconciles(gross: row["Gross Pay"], other: row["Non-Taxable Additions (Total)"], deductions: row["Total Deductions"], net: row["Net Pay"])
      end
      field = (5..9).map { |number| headers.zip(sheet.row(number)).to_h }.find { |row| row["Employee Name"] == "Field Retirement Employee" }
      expect(field["401(k)"]).to eq(927.91)
      simple = book.sheet("Payroll Register")
      header_number = (1..simple.last_row).find { |number| simple.row(number).include?("Retirement (Pre-Tax + Roth)") }
      simple_headers = simple.row(header_number)
      ((header_number + 1)..(header_number + 5)).each do |number|
        row = simple_headers.zip(simple.row(number)).to_h
        assert_reconciles(gross: row["Gross Pay"], other: row["Non-Taxable Additions"], deductions: row["Total Deductions"], net: row["Net Pay"])
      end
    end
  end

  it "flags a one-cent broken employee or contractor in simple, detailed, PDF and XLSX review" do
    items.first.update_columns(net_pay: items.first.net_pay + 0.01)
    report = register
    expect(report[:register_review]).to include(include(issue: "Payroll row does not reconcile"))
    expect(report[:simple_register][:review]).not_to include(include(severity: "OK"))
    contractor = report[:employees].find { |row| row[:employee_id] == items.first.employee_id }.merge(employee_name: "Contractor")
    expect(PayrollRegisterReconciliation.review_rows(employees: [], contractors: [ contractor ]).sole[:employee]).to eq("Contractor")
    company.update!(simple_payroll_register_enabled: false)
    get "/api/v1/admin/reports/payroll_register_xlsx", params: { pay_period_id: period.id }
    workbook { |book| expect(book.sheet("Register Review").row(2)).to include("Payroll row does not reconcile") }
    get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: period.id }
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")).to include("Payroll row does not reconcile")
  end

  it "includes manual, adjustment and field reimbursements once, including signed cents" do
    item = items.find { |candidate| candidate.non_taxable_pay.positive? }
    item.update_columns(payroll_adjustments: [ { label: "Mileage", treatment: "non_taxable_addition", amount: "0.10", source: "manual" } ], net_pay: item.net_pay + 0.30)
    definition = create(:payroll_field_definition, company: company, name: "Supplies", tax_treatment: "non_taxable_addition")
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: definition, amount: 0.20)
    row = register[:employees].find { |worker| worker[:employee_id] == item.employee_id }
    expect(row[:non_taxable_additions_total].to_d).to eq(20.30.to_d)
    expect(PayrollRegisterReconciliation.review_rows(employees: [ row ])).to be_empty
    negative = { gross_pay: -100, non_taxable_additions_total: -0.30, total_deductions: -10, net_pay: -90.30 }
    expect(PayrollRegisterReconciliation.review_rows(employees: [ negative ])).to be_empty
  end

  it "keeps employee summary and YTD additions/retirement consistent with the register" do
    get "/api/v1/admin/reports/payroll_summary_by_employee_xlsx", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok)
    workbook do |book|
      sheet = book.sheet("Employee Summary")
      headers = sheet.row(1)
      (2..6).each do |number|
        row = headers.zip(sheet.row(number)).to_h
        assert_reconciles(gross: row["Gross Pay"], other: row["Non-Taxable Additions (Total)"], deductions: row["Total Deductions"], net: row["Net Pay"])
      end
      expect(book.sheet("Totals").to_a).to include([ "401(k)", 927.91 ], [ "Roth 401(k)", 1245.15 ], [ "Non-Taxable Additions (Total)", 20.0 ])
    end
    get "/api/v1/admin/reports/ytd_summary", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    rows = response.parsed_body.dig("report", "employees")
    rows.each { |row| assert_reconciles(gross: row["gross_pay"], other: row["non_taxable_additions_total"], deductions: row["total_deductions"], net: row["net_pay"]) }
    expect(rows.find { |row| row["name"] == "Field Retirement Employee" }["retirement"]).to eq(927.91)
  end
end
