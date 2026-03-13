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
      company.update!(ein: "12-3456789")
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Main St",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
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

  # ─── W-2GU CSV Export ───────────────────────────────────────────────────────

  describe "GET /api/v1/admin/reports/w2_gu_csv" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))
    end

    before do
      company.update!(ein: "12-3456789")
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Main St",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: employee,
        gross_pay: 3000.00,
        reported_tips: 100.00,
        withholding_tax: 250.00,
        social_security_tax: 186.00,
        medicare_tax: 43.50)
    end

    it "returns 200 with CSV content-type" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "includes a Content-Disposition attachment header" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2025 }

      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(".csv")
    end

    it "includes CSV header row" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2025 }

      csv_body = response.body
      expect(csv_body.lines.first).to include("Employee Name")
      expect(csv_body.lines.first).to include("Box 1")
    end

    it "includes employee data row" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2025 }

      csv_body = response.body
      expect(csv_body).to include(employee.full_name)
      expect(csv_body).to include("3100.00")
    end

    it "includes TOTALS row" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2025 }

      expect(response.body).to include("TOTALS")
    end

    it "returns 422 for invalid year" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: "abc" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/)
    end

    it "returns 422 when SS wage base is not configured" do
      get "/api/v1/admin/reports/w2_gu_csv", params: { year: 2027 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/SS wage base not configured/)
    end

    it "defaults to current year when year param is omitted" do
      allow(Date).to receive(:today).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/w2_gu_csv"

      expect(response).to have_http_status(:ok)
    end
  end

  # ─── W-2GU PDF Export ───────────────────────────────────────────────────────

  describe "GET /api/v1/admin/reports/w2_gu_pdf" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))
    end

    before do
      company.update!(ein: "12-3456789")
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Main St",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: employee,
        gross_pay: 3000.00,
        reported_tips: 100.00,
        withholding_tax: 250.00,
        social_security_tax: 186.00,
        medicare_tax: 43.50)
    end

    it "returns 200 with PDF content-type" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end

    it "includes a Content-Disposition attachment header" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: 2025 }

      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(".pdf")
    end

    it "returns binary data starting with PDF magic bytes" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: 2025 }

      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ]) # %PDF
    end

    it "returns 422 for invalid year" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: "abc" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/)
    end

    it "returns 422 when SS wage base is not configured" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: 2027 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/SS wage base not configured/)
    end

    it "defaults to current year when year param is omitted" do
      allow(Date).to receive(:today).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/w2_gu_pdf"

      expect(response).to have_http_status(:ok)
    end

    it "generates PDF for a year with no committed payroll (empty employees list)" do
      get "/api/v1/admin/reports/w2_gu_pdf", params: { year: 2024 }

      expect(response).to have_http_status(:ok)
      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end
  end

  describe "POST /api/v1/admin/reports/w2_gu_preflight" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))
    end

    before do
      company.update!(ein: "12-3456789")
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Main St",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: employee,
        gross_pay: 3000.00,
        reported_tips: 100.00,
        withholding_tax: 250.00,
        social_security_tax: 186.00,
        medicare_tax: 43.50)
    end

    it "returns preflight structure" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      preflight = response.parsed_body["preflight"]
      expect(preflight["year"]).to eq(2025)
      expect(preflight["company_id"]).to eq(company.id)
      expect(preflight["findings"]).to be_an(Array)
      expect(preflight).to have_key("blocking_count")
      expect(preflight).to have_key("warning_count")
      expect(preflight["blocking_count"]).to eq(0)
    end

    it "flags missing SSN as blocking finding" do
      employee.update!(ssn_encrypted: nil)

      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }

      preflight = response.parsed_body["preflight"]
      ssn_finding = preflight["findings"].find { |f| f["code"] == "EMPLOYEE_SSN_MISSING" }
      expect(ssn_finding).to be_present
      expect(ssn_finding["severity"]).to eq("blocking")
      expect(preflight["blocking_count"]).to eq(1)
    end

    it "returns 422 for invalid year" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: "bad" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/i)
    end
  end

  describe "POST /api/v1/admin/reports/w2_gu_mark_ready" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))
    end

    before do
      company.update!(ein: "12-3456789")
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Main St",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
      create(:payroll_item,
        pay_period: pay_period_2025,
        employee: employee,
        gross_pay: 3000.00,
        reported_tips: 100.00,
        withholding_tax: 250.00,
        social_security_tax: 186.00,
        medicare_tax: 43.50)
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }
      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for manager users (admin-only approval action)" do
      manager_user = User.create!(
        company: company,
        email: "manager-reports-#{company.id}@example.com",
        name: "Reports Manager",
        role: "manager",
        active: true
      )
      allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(manager_user)

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to match(/Admin access required/i)
    end

    it "returns 422 when preflight has not been run" do
      W2FilingReadiness.where(company_id: company.id, year: 2025).delete_all

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/Run W-2 preflight/i)
    end

    it "marks filing ready when no blocking findings" do
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Reviewed by ops" }
      expect(response).to have_http_status(:ok)
      filing = response.parsed_body["filing"]
      expect(filing["status"]).to eq("filing_ready")
    end

    it "returns 422 when blocking findings exist" do
      employee.update!(ssn_encrypted: nil)
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/blocking findings/i)
    end

    it "revalidates preflight at mark_ready time to prevent stale blocking_count" do
      # Initial preflight is clean in before block. Introduce a new blocking issue after that.
      employee.update!(ssn_encrypted: nil)

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/blocking findings/i)

      filing = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      expect(filing.status).to eq("draft")
      expect(filing.blocking_count).to be > 0
    end

    it "does not overwrite preflight_run_at when mark_ready performs revalidation" do
      filing = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      preflight_run_at = filing.preflight_run_at
      expect(preflight_run_at).to be_present

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Reviewed by ops" }
      expect(response).to have_http_status(:ok)

      updated = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      expect(updated.preflight_run_at.to_i).to eq(preflight_run_at.to_i)
      expect(updated.status).to eq("filing_ready")
    end

    it "does not overwrite persisted findings during mark_ready revalidation" do
      filing = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      persisted_findings = filing.findings

      employee.update!(ssn_encrypted: nil)
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)

      updated = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      expect(updated.findings).to eq(persisted_findings)
      expect(updated.status).to eq("draft")
    end

    it "preserves filing_ready status and audit fields on clean preflight re-run" do
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Reviewed by ops" }
      expect(response).to have_http_status(:ok)

      filing_ready = response.parsed_body["filing"]
      expect(filing_ready["status"]).to eq("filing_ready")
      expect(filing_ready["marked_ready_at"]).to be_present
      expect(filing_ready["marked_ready_by_id"]).to be_present

      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }
      expect(response).to have_http_status(:ok)

      filing_after_rerun = response.parsed_body["filing"]
      expect(filing_after_rerun["status"]).to eq("filing_ready")
      expect(filing_after_rerun["marked_ready_at"]).to eq(filing_ready["marked_ready_at"])
      expect(filing_after_rerun["marked_ready_by_id"]).to eq(filing_ready["marked_ready_by_id"])
      expect(filing_after_rerun["findings"]).to be_an(Array)
    end

    it "does not overwrite approval audit fields on repeated mark_ready calls" do
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Initial signoff" }
      expect(response).to have_http_status(:ok)
      first = response.parsed_body["filing"]

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Attempted overwrite" }
      expect(response).to have_http_status(:ok)
      second = response.parsed_body["filing"]

      expect(second["status"]).to eq("filing_ready")
      expect(second["marked_ready_at"]).to eq(first["marked_ready_at"])
      expect(second["marked_ready_by_id"]).to eq(first["marked_ready_by_id"])
      expect(second["notes"]).to eq(first["notes"])
    end

    it "clears approval notes when filing is downgraded back to draft" do
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Reviewed and approved by ops" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("filing", "notes")).to eq("Reviewed and approved by ops")

      employee.update!(ssn_encrypted: nil)
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }
      expect(response).to have_http_status(:ok)

      filing = response.parsed_body["filing"]
      expect(filing["status"]).to eq("draft")
      expect(filing["notes"]).to be_nil
      expect(filing["marked_ready_at"]).to be_nil
      expect(filing["marked_ready_by_id"]).to be_nil
    end

    it "allows explicit note clearing when marking filing ready" do
      filing = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      filing.update!(status: "preflight_passed", notes: "stale note")

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "" }
      expect(response).to have_http_status(:ok)

      updated = response.parsed_body["filing"]
      expect(updated["status"]).to eq("filing_ready")
      expect(updated["notes"]).to be_nil
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

  # ─── CPR-70: Payroll Register CSV Export ────────────────────────────────────

  describe "GET /api/v1/admin/reports/payroll_register_csv" do
    let!(:pay_period) do
      create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 3, 1),
        end_date:   Date.new(2025, 3, 14),
        pay_date:   Date.new(2025, 3, 19))
    end

    before do
      create(:payroll_item,
        pay_period:          pay_period,
        employee:            employee,
        gross_pay:           2000.00,
        withholding_tax:     150.00,
        social_security_tax: 124.00,
        medicare_tax:        29.00,
        retirement_payment:  80.00,
        total_deductions:    383.00,
        net_pay:             1617.00)
    end

    it "returns 200 with CSV content-type" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "includes a Content-Disposition attachment header with .csv filename" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("attachment")
      expect(disposition).to include(".csv")
    end

    it "includes CSV header row with expected columns" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      first_line = response.body.lines.first
      expect(first_line).to include("Employee Name")
      expect(first_line).to include("Gross Pay")
      expect(first_line).to include("Net Pay")
    end

    it "includes employee data row" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      expect(response.body).to include(employee.full_name)
      expect(response.body).to include("2000.00")
    end

    it "includes TOTALS summary row" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      expect(response.body).to include("TOTALS")
    end

    it "returns 422 when pay_period_id is missing" do
      get "/api/v1/admin/reports/payroll_register_csv"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/pay_period_id/)
    end

    it "returns 404 for a pay period belonging to another company" do
      other_company  = create(:company)
      other_period   = create(:pay_period, :committed, company: other_company)

      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: other_period.id }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a non-existent pay period id" do
      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: 999_999 }

      expect(response).to have_http_status(:not_found)
    end
  end

  # ─── CPR-70: Payroll Register PDF Export ────────────────────────────────────

  describe "GET /api/v1/admin/reports/payroll_register_pdf" do
    let!(:pay_period) do
      create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 3, 1),
        end_date:   Date.new(2025, 3, 14),
        pay_date:   Date.new(2025, 3, 19))
    end

    before do
      create(:payroll_item,
        pay_period:          pay_period,
        employee:            employee,
        gross_pay:           2000.00,
        withholding_tax:     150.00,
        social_security_tax: 124.00,
        medicare_tax:        29.00,
        retirement_payment:  80.00,
        total_deductions:    383.00,
        net_pay:             1617.00)
    end

    it "returns 200 with PDF content-type" do
      get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end

    it "includes a Content-Disposition attachment header with .pdf filename" do
      get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("attachment")
      expect(disposition).to include(".pdf")
    end

    it "returns binary data starting with PDF magic bytes" do
      get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }

      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ]) # %PDF
    end

    it "generates PDF even with no payroll items (empty period)" do
      empty_period = create(:pay_period, :committed, company: company,
        start_date: Date.new(2025, 4, 1), end_date: Date.new(2025, 4, 14), pay_date: Date.new(2025, 4, 19))

      get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: empty_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end

    it "returns 422 when pay_period_id is missing" do
      get "/api/v1/admin/reports/payroll_register_pdf"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/pay_period_id/)
    end

    it "returns 404 for a pay period belonging to another company" do
      other_company = create(:company)
      other_period  = create(:pay_period, :committed, company: other_company)

      get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: other_period.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  # ─── CPR-70: Tax Summary CSV Export ─────────────────────────────────────────

  describe "GET /api/v1/admin/reports/tax_summary_csv" do
    let!(:pay_period_q1) do
      create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 2, 1),
        end_date:   Date.new(2025, 2, 14),
        pay_date:   Date.new(2025, 2, 19))
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
        employer_medicare_tax:         43.50)
    end

    it "returns 200 with CSV content-type" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "includes a Content-Disposition attachment header with .csv filename" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025 }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("attachment")
      expect(disposition).to include(".csv")
    end

    it "includes period metadata in the CSV body" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025 }

      expect(response.body).to include("Tax Summary Report")
      expect(response.body).to include("2025")
    end

    it "includes Gross Wages total line" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025 }

      expect(response.body).to include("Gross Wages")
      expect(response.body).to include("3000.00")
    end

    it "filters by quarter when provided" do
      q3_period = create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 7, 1),
        end_date:   Date.new(2025, 7, 14),
        pay_date:   Date.new(2025, 7, 19))
      create(:payroll_item,
        pay_period:                   q3_period,
        employee:                     employee,
        gross_pay:                    5000.00,
        withholding_tax:              300.00,
        social_security_tax:          310.00,
        employer_social_security_tax: 310.00,
        medicare_tax:                  72.50,
        employer_medicare_tax:         72.50)

      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025, quarter: 1 }

      # Q1 only — should show Q1 gross, not Q3
      expect(response.body).to include("3000.00")
      expect(response.body).not_to include("5000.00")
    end

    it "returns 422 for an invalid quarter" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025, quarter: 5 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/quarter/)
    end

    it "defaults to current year when year param is omitted" do
      allow(Date).to receive(:today).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/tax_summary_csv"

      expect(response).to have_http_status(:ok)
    end

    it "includes Q label when quarter is provided" do
      get "/api/v1/admin/reports/tax_summary_csv", params: { year: 2025, quarter: 1 }

      expect(response.body).to include("Q1")
    end
  end

  # ─── CPR-70: Tax Summary PDF Export ─────────────────────────────────────────

  describe "GET /api/v1/admin/reports/tax_summary_pdf" do
    let!(:pay_period_2025) do
      create(:pay_period, :committed,
        company:    company,
        start_date: Date.new(2025, 2, 1),
        end_date:   Date.new(2025, 2, 14),
        pay_date:   Date.new(2025, 2, 19))
    end

    before do
      create(:payroll_item,
        pay_period:                   pay_period_2025,
        employee:                     employee,
        gross_pay:                    3000.00,
        withholding_tax:              200.00,
        social_security_tax:          186.00,
        employer_social_security_tax: 186.00,
        medicare_tax:                  43.50,
        employer_medicare_tax:         43.50)
    end

    it "returns 200 with PDF content-type" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end

    it "includes a Content-Disposition attachment header with .pdf filename" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025 }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("attachment")
      expect(disposition).to include(".pdf")
    end

    it "returns binary data starting with PDF magic bytes" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025 }

      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end

    it "generates PDF for a quarter with no payroll (empty totals)" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025, quarter: 4 }

      expect(response).to have_http_status(:ok)
      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end

    it "returns 422 for an invalid quarter" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025, quarter: 0 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/quarter/)
    end

    it "defaults to current year when year param is omitted" do
      allow(Date).to receive(:today).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/tax_summary_pdf"

      expect(response).to have_http_status(:ok)
    end

    it "includes quarter filter in filename when quarter is provided" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025, quarter: 2 }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("q2")
    end
  end
end
