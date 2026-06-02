# frozen_string_literal: true

require "rails_helper"

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

  it "limits ytd summary to committed pay periods" do
    get "/api/v1/client/reports/ytd_summary", params: { year: 2026 }

    expect(response).to have_http_status(:ok)
    report = response.parsed_body.fetch("report")
    expect(report.dig("company_totals", "gross_pay").to_f).to eq(1450.0)
    expect(report.dig("company_totals", "custom_earnings_total").to_f).to eq(50.0)
    expect(report.dig("company_totals", "custom_deductions_total").to_f).to eq(30.0)
    expect(report.dig("company_totals", "payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
    expect(report.fetch("employees").first.fetch("gross_pay").to_f).to eq(1450.0)
    expect(report.fetch("employees").first.fetch("custom_earnings_total").to_f).to eq(50.0)
    expect(report.fetch("employees").first.fetch("custom_deductions_total").to_f).to eq(30.0)
    expect(report.fetch("employees").first.fetch("payroll_field_post_tax_deductions_total").to_f).to eq(75.0)
  end
end
