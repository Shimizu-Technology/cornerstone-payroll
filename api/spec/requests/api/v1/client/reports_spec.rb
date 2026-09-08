# frozen_string_literal: true

require "rails_helper"
require "csv"
require "pdf/reader"
require "roo"

RSpec.describe "Api::V1::Client::Reports", type: :request do
  let!(:company) { create(:company, name: "Reports Co") }
  let!(:department) { create(:department, company: company) }
  let!(:client_user) { create(:user, company: company, role: "client", email: "reports-client@example.com") }
  let!(:employee) { create(:employee, company: company, department: department, first_name: "Ana", last_name: "Perez") }
  let!(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 18))
  end
  let!(:draft_pay_period) do
    create(:pay_period,
      company: company,
      start_date: Date.new(2026, 4, 15),
      end_date: Date.new(2026, 4, 28),
      pay_date: Date.new(2026, 5, 2),
      status: "draft")
  end

  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 1450.0,
      net_pay: 1170.0,
      withholding_tax: 120.0,
      social_security_tax: 89.9,
      employer_social_security_tax: 89.9,
      medicare_tax: 20.3,
      employer_medicare_tax: 20.3,
      total_deductions: 280.0,
      custom_earnings: [ { "label" => "Certification Pay", "amount" => 50.0 } ],
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 30.0 } ])
  end

  let!(:payroll_field_definition) do
    PayrollFieldDefinition.create!(
      company: company,
      name: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent"
    )
  end

  let!(:payroll_field_entry) do
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: payroll_field_definition,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 75.0,
      source: "manual"
    )
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)

    create(:payroll_item,
      pay_period: draft_pay_period,
      employee: employee,
      company: company,
      gross_pay: 9999.0,
      net_pay: 8000.0,
      withholding_tax: 800.0,
      social_security_tax: 619.94,
      employer_social_security_tax: 619.94,
      medicare_tax: 144.99,
      employer_medicare_tax: 144.99)

    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(company.id)
  end

  def create_client_historical_paycheck(employee:, suffix:, gross_pay: 400, net_pay: 290)
    batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "QuickBooks #{suffix}",
      bundle_digest: "client-reports-#{company.id}-#{suffix}",
      importer_version: "quickbooks-online-payroll-v5",
      status: "locked",
      locked_at: Time.zone.parse("2026-03-25 09:00"),
      locked_by: client_user
    )
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "period-#{suffix}",
      source_label: "Payroll #{suffix}",
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 20),
      paycheck_count: 1,
      totals: { "gross_pay" => gross_pay.to_s, "net_pay" => net_pay.to_s }
    )
    worker = HistoricalWorker.create!(
      historical_import_batch: batch,
      company: company,
      employee: employee,
      external_key: "worker-#{suffix}",
      source_name: employee&.full_name || "Unlinked Worker",
      normalized_name: employee&.full_name&.downcase || "unlinked worker",
      source_status: "active",
      mapping_status: employee ? "exact_match" : "archive_only"
    )
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "check-#{suffix}",
      source_employee_name: employee&.full_name || "Unlinked Worker",
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: employee ? "matched" : "unmatched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      gross_pay: gross_pay,
      adjusted_gross: gross_pay,
      employee_taxes: 80,
      federal_income_tax: 50,
      social_security_tax: 25,
      medicare_tax: 5,
      after_tax_deductions: 30,
      net_pay: net_pay
    )
  end

  it "exposes the dashboard and read-only payroll register to client users" do
    get "/api/v1/client/reports/dashboard"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("stats", "ytd_totals", "gross_pay").to_f).to eq(1450.0)

    get "/api/v1/client/reports/payroll_register", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("report", "summary", "employee_count")).to eq(1)
    expect(response.parsed_body.dig("report", "summary", "total_custom_earnings").to_f).to eq(50.0)
    expect(response.parsed_body.dig("report", "summary", "total_custom_deductions").to_f).to eq(30.0)
    expect(response.parsed_body.dig("report", "summary", "total_payroll_field_post_tax_deductions").to_f).to eq(75.0)
    employee_row = response.parsed_body.dig("report", "employees", 0)
    expect(employee_row).not_to have_key("check_number")
    expect(employee_row.dig("payroll_field_entries", 0, "label")).to eq("Rent Deduction")
    expect(employee_row.dig("payroll_field_entries", 0, "amount").to_f).to eq(75.0)

    get "/api/v1/client/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("application/pdf")
    expect(response.body).to start_with("%PDF")
  end

  it "exports the client payroll register in CSV and Excel from the same committed snapshot" do
    get "/api/v1/client/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/csv")
    csv_rows = CSV.parse(response.body)
    expect(csv_rows.flatten).to include("Ana Perez", "75.00")

    get "/api/v1/client/reports/payroll_register_xlsx", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("spreadsheetml")
    workbook = Roo::Excelx.new(StringIO.new(response.body))
    expect(workbook.sheets).to include("Employees", "Payroll Fields Detail", "Payroll Fields Totals")
  end

  it "does not export a draft payroll register to client users" do
    %w[payroll_register_csv payroll_register_pdf payroll_register_xlsx].each do |action|
      get "/api/v1/client/reports/#{action}", params: { pay_period_id: draft_pay_period.id }

      expect(response).to have_http_status(:not_found), "expected #{action} to reject a draft pay period"
    end
  end

  it "limits ytd summary to committed pay periods" do
    create_client_historical_paycheck(employee: employee, suffix: "linked")
    create_client_historical_paycheck(employee: nil, suffix: "unlinked", gross_pay: 125, net_pay: 90)

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026 }

    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.dig("company_totals", "gross_pay").to_f).to eq(1850.0)
    expect(report.dig("company_totals", "custom_earnings_total").to_f).to eq(50.0)
    expect(report.dig("company_totals", "custom_deductions_total").to_f).to eq(30.0)
    expect(report.dig("company_totals", "payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
    expect(report.fetch("employees").first.fetch("gross_pay").to_f).to eq(1850.0)
    expect(report.fetch("employees").first.fetch("custom_earnings_total").to_f).to eq(50.0)
    expect(report.fetch("employees").first.fetch("custom_deductions_total").to_f).to eq(30.0)
    expect(report.fetch("employees").first.fetch("payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
    expect(report.dig("payroll_fields", "totals", 0, "label")).to eq("Rent Deduction")
    expect(report.dig("payroll_fields", "entries", 0)).to include(
      "employee_name" => "Ana Perez",
      "label" => "Rent Deduction",
      "tax_treatment" => "post_tax_deduction",
      "source" => "manual"
    )
    expect(report.dig("payroll_fields", "entries", 0, "amount").to_f).to eq(75.0)
    expect(report.dig("source_summary", "quickbooks")).to include(
      "payroll_count" => 1,
      "paycheck_count" => 1,
      "excluded_unlinked_paycheck_count" => 1,
      "excluded_unlinked_gross_pay" => 125.0
    )
    expect(report.dig("source_summary", "source_statement")).to include("not recalculated")
  end

  it "exports the client payroll summary as PDF, Excel, and CSV with matching totals" do
    get "/api/v1/client/reports/ytd_summary_csv", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    csv_rows = CSV.parse(response.body)
    ana_row = csv_rows.find { |row| row.include?("Ana Perez") }
    expect(ana_row).to include("1450.0")

    get "/api/v1/client/reports/ytd_summary_xlsx", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    workbook = Roo::Excelx.new(StringIO.new(response.body))
    expect(workbook.sheets).to include("Payroll Summary", "Company Totals", "Payroll Sources", "Payroll Field Activity")

    get "/api/v1/client/reports/ytd_summary_pdf", params: { year: 2026 }
    expect(response).to have_http_status(:ok)
    reader = PDF::Reader.new(StringIO.new(response.body))
    text = reader.pages.map(&:text).join("\n")
    expect(text).to include("Payroll Summary by Period")
    expect(text).to include("Ana Perez")
    expect(text).to include("Rent Deduction")
  end

  it "allows client users to review and export year-by-year payroll totals" do
    create_client_historical_paycheck(employee: employee, suffix: "annual-linked")

    get "/api/v1/client/reports/annual_payroll_summary"
    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.fetch("years").pluck("year")).to eq([ 2026 ])
    expect(report.dig("years", 0, "cornerstone_payroll_count")).to eq(1)
    expect(report.dig("years", 0, "quickbooks_payroll_count")).to eq(1)
    expect(report.dig("totals", "gross_pay").to_f).to eq(1_850.0)

    %w[csv pdf xlsx].each do |format|
      get "/api/v1/client/reports/annual_payroll_summary_#{format}"
      expect(response).to have_http_status(:ok), "expected client #{format} export to succeed"
    end
  end
end
