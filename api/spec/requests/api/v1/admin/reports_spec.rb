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

  describe "GET /api/v1/admin/reports/form_941_gu" do
    let!(:pay_period_q1) do
      create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 1,  1),
        end_date:   Date.new(2025, 1, 14),
        pay_date:   Date.new(2025, 1, 18))
    end

    before do
      create(:payroll_item,
        pay_period:                   pay_period_q1,
        employee:                     employee,
        gross_pay:                    3000.00,
        withholding_tax:              200.00,
        social_security_tax:          186.00,
        employer_social_security_tax: 186.00,
        medicare_tax:                  43.50,
        employer_medicare_tax:         43.50,
        reported_tips:                 0.00)
    end

    it "returns 200 with correct structure for a valid quarter" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["report"]

      expect(body["meta"]["report_type"]).to eq("form_941_gu")
      expect(body["meta"]["year"]).to eq(2025)
      expect(body["meta"]["quarter"]).to eq(1)
      expect(body["meta"]["quarter_label"]).to eq("Q1 2025")
      expect(body["meta"]["pay_periods_included"]).to eq(1)
      expect(body["meta"]["caveats"]).to be_an(Array)
    end

    it "returns correct line values" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      lines = response.parsed_body.dig("report", "lines")
      expect(lines["line1_employee_count"]).to eq(1)
      expect(lines["line2_wages_tips_other"].to_f).to eq(3000.0)
      expect(lines["line3_fit_withheld"].to_f).to eq(200.0)
      expect(lines["line5a_ss_combined_tax"].to_f).to eq(372.0)  # 186 + 186
      expect(lines["line5c_medicare_combined_tax"].to_f).to eq(87.0) # 43.5 + 43.5
    end

    it "includes tax_detail and monthly_liability" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      body = response.parsed_body["report"]
      expect(body["tax_detail"]).to be_a(Hash)
      expect(body["monthly_liability"]).to be_an(Array)
      expect(body["monthly_liability"].length).to eq(3)
    end

    it "returns 422 when quarter param is missing" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/quarter/)
    end

    it "returns 422 when quarter is out of range" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 5 }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns empty data (not error) for a quarter with no payroll" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 3 }
      expect(response).to have_http_status(:ok)
      lines = response.parsed_body.dig("report", "lines")
      expect(lines["line2_wages_tips_other"].to_f).to eq(0.0)
      expect(lines["line1_employee_count"]).to eq(0)
    end

    it "nil placeholder lines are present in response" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }
      lines = response.parsed_body.dig("report", "lines")
      expect(lines).to have_key("line7_adj_fractions_cents")
      expect(lines["line7_adj_fractions_cents"]).to be_nil
      expect(lines).to have_key("line13_total_deposits")
      expect(lines["line13_total_deposits"]).to be_nil
    end
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
