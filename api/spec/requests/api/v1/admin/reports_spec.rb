# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Reports", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "admin-reports-#{company.id}@example.com",
      name: "Reports Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(admin_user)
  end

  describe "GET /api/v1/admin/reports/tax_summary" do
    it "uses dedicated employer tax fields in totals" do
      pay_period = create(:pay_period, company: company, status: "committed", pay_date: Date.new(2026, 2, 13))
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        gross_pay: 1000.00,
        withholding_tax: 100.00,
        social_security_tax: 62.00,
        employer_social_security_tax: 62.00,
        medicare_tax: 23.00,
        employer_medicare_tax: 14.50
      )

      get "/api/v1/admin/reports/tax_summary", params: { year: 2026 }

      expect(response).to have_http_status(:ok)
      totals = response.parsed_body.dig("report", "totals")
      expect(totals["social_security_employer"].to_f).to eq(62.0)
      expect(totals["medicare_employer"].to_f).to eq(14.5)
      expect(totals["total_employment_taxes"].to_f).to eq(261.5)
    end
  end
end
