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

  before do
    CompanyAssignment.create!(user: client_user, company: company)
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
      employer_medicare_tax: 20.3)

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

    get "/api/v1/client/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("application/pdf")
    expect(response.body).to start_with("%PDF")
  end
end
