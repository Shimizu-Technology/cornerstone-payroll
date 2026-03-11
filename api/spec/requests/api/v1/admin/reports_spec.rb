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

    it "includes reported tips in line2_wages_tips_other" do
      create(:payroll_item,
        pay_period:                   pay_period_q1,
        employee:                     create(:employee, company: company, department: department),
        gross_pay:                    1000.00,
        withholding_tax:              75.00,
        social_security_tax:          62.00,
        employer_social_security_tax: 62.00,
        medicare_tax:                 14.50,
        employer_medicare_tax:        14.50,
        reported_tips:                100.00)

      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      lines = response.parsed_body.dig("report", "lines")
      expect(lines["line2_wages_tips_other"].to_f).to eq(4100.0) # 3000 + 1000 + 100 tips
    end

    it "includes tax_detail and monthly_liability" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      body = response.parsed_body["report"]
      expect(body["tax_detail"]).to be_a(Hash)
      expect(body["monthly_liability"]).to be_an(Array)
      expect(body["monthly_liability"].length).to eq(3)
    end

    it "returns 422 when year is non-numeric" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: "abc", quarter: 1 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/)
    end

    it "returns 422 when SS wage base is not configured for the requested year" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2026, quarter: 1 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/SS wage base not configured/)
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

  describe "GET /api/v1/admin/reports/w2_gu" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))
    end

    before do
      employee.update!(ssn_encrypted: "123-45-6789")
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: employee,
        gross_pay: 3000.00,
        reported_tips: 100.00,
        withholding_tax: 250.00,
        social_security_tax: 186.00,
        medicare_tax: 43.50)
    end

    it "returns 200 with W-2GU structure" do
      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      report = response.parsed_body["report"]
      expect(report.dig("meta", "report_type")).to eq("w2_gu")
      expect(report.dig("meta", "year")).to eq(2025)
      expect(report["employees"]).to be_an(Array)
      expect(report["totals"]).to be_a(Hash)
    end

    it "returns expected employee totals" do
      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      employee_row = response.parsed_body.dig("report", "employees", 0)
      totals = response.parsed_body.dig("report", "totals")

      expect(employee_row["box1_wages_tips_other_comp"].to_f).to eq(3100.0)
      expect(employee_row["box2_federal_income_tax_withheld"].to_f).to eq(250.0)
      expect(employee_row["box3_social_security_wages"].to_f).to eq(3000.0)
      expect(employee_row["box4_social_security_tax_withheld"].to_f).to eq(186.0)
      expect(employee_row["box5_medicare_wages_tips"].to_f).to eq(3100.0)
      expect(employee_row["box6_medicare_tax_withheld"].to_f).to eq(43.5)
      expect(employee_row["box7_social_security_tips"].to_f).to eq(100.0)

      expect(totals["box1_wages_tips_other_comp"].to_f).to eq(3100.0)
      expect(totals["box2_federal_income_tax_withheld"].to_f).to eq(250.0)
      expect(totals["box3_social_security_wages"].to_f).to eq(3000.0)
      expect(totals["box4_social_security_tax_withheld"].to_f).to eq(186.0)
      expect(totals["box5_medicare_wages_tips"].to_f).to eq(3100.0)
      expect(totals["box6_medicare_tax_withheld"].to_f).to eq(43.5)
      expect(totals["box7_social_security_tips"].to_f).to eq(100.0)
      expect(totals["reported_tips_total"].to_f).to eq(100.0)
    end

    it "flags missing SSN as compliance issue" do
      employee.update!(ssn_encrypted: nil)

      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      issues = response.parsed_body.dig("report", "compliance_issues")
      expect(issues.join(" ")).to match(/missing SSN/)
    end

    it "flags missing employer and employee addresses as compliance issues" do
      company.update!(address_line1: nil, city: nil, state: nil, zip: nil)
      employee.update!(address_line1: nil, city: nil, state: nil, zip: nil)

      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      issues = response.parsed_body.dig("report", "compliance_issues")
      expect(issues.join(" ")).to match(/Employer address is missing/)
      expect(issues.join(" ")).to match(/employee\(s\) missing address/)
    end

    it "counts only employees with committed payroll in the year" do
      create(:employee, company: company, department: department, ssn_encrypted: "987-65-4321")

      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      meta = response.parsed_body.dig("report", "meta")
      expect(meta["employee_count"]).to eq(1)
      expect(response.parsed_body.dig("report", "employees").length).to eq(1)
    end

    it "does not back-calculate box5 from medicare tax when additional medicare applies" do
      high_earner = create(:employee, company: company, department: department, ssn_encrypted: "555-55-5555")
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: high_earner,
        gross_pay: 250_000.00,
        reported_tips: 0.00,
        withholding_tax: 20_000.00,
        social_security_tax: 10_918.20,
        medicare_tax: 4_075.00)

      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      row = response.parsed_body.dig("report", "employees").find { |r| r["employee_id"] == high_earner.id }
      expect(row["box5_medicare_wages_tips"].to_f).to eq(250_000.0)
      expect(row["box3_social_security_wages"].to_f).to be < 250_000.0
      expect(row["box3_social_security_wages"].to_f).to eq(176_100.0)
    end

    it "caps box7 at SS wage base and reduces box3 remaining base" do
      tipped_high_earner = create(:employee, company: company, department: department, ssn_encrypted: "444-44-4444")
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: tipped_high_earner,
        gross_pay: 50_000.00,
        reported_tips: 200_000.00,
        withholding_tax: 10_000.00,
        social_security_tax: 10_918.20,
        medicare_tax: 3_625.00)

      get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

      row = response.parsed_body.dig("report", "employees").find { |r| r["employee_id"] == tipped_high_earner.id }
      expect(row["box3_social_security_wages"].to_f).to eq(50_000.0)
      expect(row["box5_medicare_wages_tips"].to_f).to eq(250_000.0)
      expect(row["box7_social_security_tips"].to_f).to eq(126_100.0)
      expect(row["reported_tips_total"].to_f).to eq(200_000.0)
      expect(row["box7_limited_by_wage_base"]).to eq(true)
    end

    it "defaults to current year when year param is omitted" do
      allow(Date).to receive(:today).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/w2_gu"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("report", "meta", "year")).to eq(2025)
    end

    it "returns 422 for invalid year" do
      get "/api/v1/admin/reports/w2_gu", params: { year: "abc" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/)
    end

    it "returns 200 for configured current-year wage base" do
      get "/api/v1/admin/reports/w2_gu", params: { year: 2026 }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("report", "meta", "year")).to eq(2026)
    end

    it "returns 422 when SS wage base is not configured for year" do
      get "/api/v1/admin/reports/w2_gu", params: { year: 2027 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/SS wage base not configured/)
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
