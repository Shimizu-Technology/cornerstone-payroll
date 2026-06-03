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

  describe "GET /api/v1/admin/reports/transmittal_preview" do
    let!(:pay_period) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 1, 14),
        pay_date: Date.new(2026, 1, 16))
    end

    before do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        check_number: "1007",
        gross_pay: 1200.00,
        net_pay: 968.20,
        withholding_tax: 100.00,
        social_security_tax: 74.40,
        employer_social_security_tax: 74.40,
        medicare_tax: 17.40,
        employer_medicare_tax: 17.40)
    end

    it "reports non-contiguous check numbers as exact ranges" do
      create(:payroll_item,
        pay_period: pay_period,
        employee: create(:employee, company: company),
        company: company,
        check_number: "1010",
        gross_pay: 100.00)
      create(:payroll_item,
        pay_period: pay_period,
        employee: create(:employee, company: company),
        company: company,
        check_number: "1011",
        gross_pay: 100.00)

      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: pay_period.id }

      payroll_checks = response.parsed_body["payroll_checks"]
      expect(payroll_checks["numbers"]).to eq(%w[1007 1010 1011])
      expect(payroll_checks["ranges"]).to eq("1007, 1010-1011")
    end

    it "reports total DRT deposit as FIT only" do
      get "/api/v1/admin/reports/transmittal_preview", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      tax_totals = response.parsed_body["tax_totals"]
      expect(tax_totals["fit"].to_f).to eq(100.0)
      expect(tax_totals["total_fica"].to_f).to eq(183.6)
      expect(tax_totals["total_drt_deposit"].to_f).to eq(100.0)
    end

    it "preserves a saved transmittal date when a later generation omits the date param" do
      Transmittal.create!(
        pay_period: pay_period,
        company: company,
        transmittal_date: Date.new(2026, 1, 20)
      )

      post "/api/v1/admin/reports/transmittal_log_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(pay_period.transmittal.reload.transmittal_date).to eq(Date.new(2026, 1, 20))
    end
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

      expect(body["meta"]["report_type"]).to eq("federal_form_941")
      expect(body["meta"]["year"]).to eq(2025)
      expect(body["meta"]["quarter"]).to eq(1)
      expect(body["meta"]["quarter_label"]).to eq("Q1 2025")
      expect(body["meta"]["pay_periods_included"]).to eq(1)
      expect(body["meta"]["caveats"]).to be_an(Array)
    end

    it "returns correct line values" do
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 1 }

      lines = response.parsed_body.dig("report", "lines")
      expect(lines["line1_employee_count"]).to eq(0)
      expect(lines["line2_wages_tips_other"]).to be_nil
      expect(lines["line3_fit_withheld"]).to be_nil
      expect(lines["line5a_ss_combined_tax"].to_f).to eq(372.0)  # 186 + 186
      expect(lines["line5c_medicare_combined_tax"].to_f).to eq(87.0) # 43.5 + 43.5
    end

    it "keeps Guam employers' Form 941 line 2 skipped even when tips exist" do
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
      expect(lines["line2_wages_tips_other"]).to be_nil
      expect(response.parsed_body.dig("report", "tax_detail", "gross_wages").to_f).to eq(4000.0)
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
      get "/api/v1/admin/reports/form_941_gu", params: { year: 2027, quarter: 1 }
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
      expect(lines["line2_wages_tips_other"]).to be_nil
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

    it "counts employees whose Q2 pay period spans June 12" do
      q2_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 6, 1),
        end_date: Date.new(2025, 6, 15),
        pay_date: Date.new(2025, 6, 20))

      create(:payroll_item,
        pay_period: q2_period,
        employee: employee,
        gross_pay: 1200.0,
        withholding_tax: 100.0,
        social_security_tax: 74.4,
        employer_social_security_tax: 74.4,
        medicare_tax: 17.4,
        employer_medicare_tax: 17.4,
        reported_tips: 0.0)

      get "/api/v1/admin/reports/form_941_gu", params: { year: 2025, quarter: 2 }

      lines = response.parsed_body.dig("report", "lines")
      expect(lines["line1_employee_count"]).to eq(1)
    end
  end

  describe "GET /api/v1/admin/reports/quarterly_compliance_packet" do
    let!(:pay_period_q1) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 3, 16),
        end_date: Date.new(2026, 3, 29),
        pay_date: Date.new(2026, 4, 2))
    end

    let!(:pay_period_q2) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 16))
    end

    before do
      create(:payroll_item,
        pay_period: pay_period_q1,
        employee: employee,
        company: company,
        gross_pay: 1000.00,
        withholding_tax: 80.00,
        social_security_tax: 62.00,
        employer_social_security_tax: 62.00,
        medicare_tax: 14.50,
        employer_medicare_tax: 14.50)

      item = create(:payroll_item,
        pay_period: pay_period_q2,
        employee: employee,
        company: company,
        gross_pay: 1200.00,
        withholding_tax: 90.00,
        social_security_tax: 74.40,
        employer_social_security_tax: 74.40,
        medicare_tax: 17.40,
        employer_medicare_tax: 17.40,
        reported_tips: 100.00,
        non_taxable_pay: 25.00)
      item.payroll_item_earnings.create!(category: "regular", label: "Regular Pay", amount: 1100.00)
      item.payroll_item_earnings.create!(category: "tips", label: "Tips", amount: 100.00)
      item.payroll_item_earnings.create!(category: "non_taxable", label: "Non-Taxable Pay", amount: 25.00)
    end

    it "builds a Q2 packet by pay date, not period end date" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:ok)
      report = response.parsed_body["report"]

      expect(report.dig("meta", "period_basis")).to eq("pay_date")
      expect(report.dig("meta", "pay_periods_included")).to eq(2)
      expect(report.dig("w1", "total_guam_withholding").to_f).to eq(170.0)
      expect(report.dig("swica", "totals", "employee_count")).to eq(1)
      expect(report.dig("swica", "totals", "total_wages").to_f).to eq(2200.0)
      expect(report.dig("federal_941", "report", "lines", "line2_wages_tips_other")).to be_nil
      expect(report.dig("federal_941", "deposit_schedule", "firm_payment_policy")).to eq("pay_each_pay_period")
    end

    it "creates a persistent workflow packet with default filing tasks" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:ok)
      workflow = response.parsed_body.dig("report", "workflow")
      expect(workflow["tasks"].map { |task| task["task_type"] }).to contain_exactly("form_500", "w1", "swica", "federal_941", "schedule_b")

      task = workflow["tasks"].find { |row| row["task_type"] == "w1" }
      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: {
          status: "filed",
          filing_confirmation_number: "W1-ABC-123",
          proof_attached: true
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("filed")
      expect(response.parsed_body.dig("task", "filing_confirmation_number")).to eq("W1-ABC-123")
      expect(response.parsed_body.dig("task", "proof_attached")).to eq(true)

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { status: "not_started" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("not_started")
    end

    it "downgrades filed_and_paid status when one completion date is cleared" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      task = response.parsed_body.dig("report", "workflow", "tasks").find { |row| row["task_type"] == "form_500" }
      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: {
          status: "filed_and_paid",
          filed_at: "2026-04-30T10:00:00Z",
          paid_at: "2026-04-30T10:05:00Z"
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("filed_and_paid")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { paid_at: nil }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("filed")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: {
          filed_at: nil,
          paid_at: "2026-04-30T10:05:00Z",
          status: "filed_and_paid"
        }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("paid")
    end

    it "downgrades filed and paid terminal statuses when their completion date is cleared" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      task = response.parsed_body.dig("report", "workflow", "tasks").find { |row| row["task_type"] == "w1" }
      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { status: "filed", filed_at: "2026-04-30T10:00:00Z" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("filed")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { filed_at: nil }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("ready_to_file")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { status: "paid", paid_at: "2026-04-30T10:05:00Z" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("paid")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { paid_at: nil }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("ready_to_file")
    end

    it "promotes needs_review tasks when filing or payment dates are recorded" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      task = response.parsed_body.dig("report", "workflow", "tasks").find { |row| row["task_type"] == "schedule_b" }
      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { status: "needs_review" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("needs_review")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { filed_at: "2026-04-30T10:00:00Z" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("filed")

      patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task["id"]}", params: {
        task: { status: "needs_review", filed_at: nil, paid_at: "2026-04-30T10:05:00Z" }
      }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("task", "status")).to eq("paid")
    end

    it "recovers from a concurrent packet provisioning uniqueness race" do
      packet = QuarterlyCompliancePacket.create!(company: company, year: 2026, quarter: 2)
      allow(QuarterlyCompliancePacket).to receive(:create_with).and_raise(ActiveRecord::RecordNotUnique.new("duplicate packet"))

      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("report", "workflow", "id")).to eq(packet.id)
    end

    it "does not count Form 500 payment-date-only rows as reconciled payments" do
      pay_period_q1.create_form500_filing!(
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        fields: Form500Generator.default_fields(company: company, pay_period: pay_period_q1),
        status: "paid",
        payment_date: Date.new(2026, 4, 3),
        payment_amount: nil
      )
      pay_period_q2.create_form500_filing!(
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        fields: Form500Generator.default_fields(company: company, pay_period: pay_period_q2),
        status: "paid",
        payment_date: Date.new(2026, 4, 17),
        payment_amount: nil
      )

      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:ok)
      form500 = response.parsed_body.dig("report", "form_500")
      check = response.parsed_body.dig("report", "review_checks").find { |row| row["key"] == "form_500_payments_reconciled" }
      expect(form500["total_confirmed_payments"].to_f).to eq(0.0)
      expect(form500["unconfirmed_amount_count"]).to eq(2)
      expect(form500["unreconciled_balance"].to_f).to eq(170.0)
      expect(check["status"]).to eq("needs_review")
    end

    it "returns 422 for invalid quarter" do
      get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 5 }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/admin/reports/quarterly_compliance_packet official PDFs" do
    let!(:pay_period_q2) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 16))
    end

    before do
      company.update!(ein: "12-3456789")
      employee.update!(ssn_encrypted: "123-45-6789")
      item = create(:payroll_item,
        pay_period: pay_period_q2,
        employee: employee,
        company: company,
        gross_pay: 1200.00,
        withholding_tax: 90.00,
        social_security_tax: 74.40,
        employer_social_security_tax: 74.40,
        medicare_tax: 17.40,
        employer_medicare_tax: 17.40,
        reported_tips: 100.00)
      item.payroll_item_earnings.create!(category: "regular", label: "Regular Pay", amount: 1100.00)
      item.payroll_item_earnings.create!(category: "tips", label: "Tips", amount: 100.00)
    end

    {
      "quarterly_compliance_packet_form_941_pdf" => "federal_form_941_2026_q2.pdf",
      "quarterly_compliance_packet_schedule_b_pdf" => "federal_form_941_schedule_b_2026_q2.pdf",
      "quarterly_compliance_packet_w1_pdf" => "guam_w1_2026_q2.pdf",
      "quarterly_compliance_packet_swica_pdf" => "guam_sw2_2026_q2.pdf"
    }.each do |endpoint, filename|
      it "returns a prefilled official PDF from #{endpoint}" do
        get "/api/v1/admin/reports/#{endpoint}", params: { year: 2026, quarter: 2 }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/pdf")
        expect(response.headers["Content-Disposition"]).to include("attachment")
        expect(response.headers["Content-Disposition"]).to include(filename)
        expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
      end
    end

    it "exports a validated SWICA ASCII wage file" do
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Marine Dr",
        city: "Tamuning",
        state: "GU",
        zip: "96913"
      )

      get "/api/v1/admin/reports/quarterly_compliance_packet_swica_ascii", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("swica_2026_q2.txt")
      first_record = response.body.lines.first.chomp
      expect(first_record.length).to eq(275)
      expect(first_record[0]).to eq("W")
      expect(first_record[1, 9]).to eq("123456789")
      expect(first_record[133]).to eq("2")
      expect(first_record[274]).to eq("S")
    end

    it "returns 422 instead of 500 when SWICA export encounters stale employee rows" do
      employee.update!(
        ssn_encrypted: "123-45-6789",
        address_line1: "123 Marine Dr",
        city: "Tamuning",
        state: "GU",
        zip: "96913"
      )
      exporter = instance_double(SwicaAsciiExporter)
      allow(SwicaAsciiExporter).to receive(:new).and_return(exporter)
      allow(exporter).to receive(:filename).and_return("swica_2026_q2.txt")
      allow(exporter).to receive(:generate).and_raise(KeyError, "key not found: 123")

      get "/api/v1/admin/reports/quarterly_compliance_packet_swica_ascii", params: { year: 2026, quarter: 2 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("key not found")
    end

    it "returns editable official form defaults with split employer address fields" do
      company.update!(
        address_line1: "1780 Admiral Sherman Boulevard",
        city: "Tiyan",
        state: "GU",
        zip: "96913"
      )

      get "/api/v1/admin/reports/quarterly_compliance_packet_official_form_defaults",
        params: { year: 2026, quarter: 2, form_type: "form_941" }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ein"]).to eq("12-3456789")
      expect(data["company_address_line1"]).to eq("1780 Admiral Sherman Boulevard")
      expect(data["company_city"]).to eq("Tiyan")
      expect(data["company_state"]).to eq("GU")
      expect(data["company_zip"]).to eq("96913")
    end

    it "previews official PDFs using reviewed field overrides" do
      post "/api/v1/admin/reports/quarterly_compliance_packet_official_form_preview",
        params: {
          year: 2026,
          quarter: 2,
          form_type: "schedule_b",
          fields: {
            company_name: "Reviewed Company Name",
            ein: "98-7654321",
            daily_liabilities: [
              { pay_date: "2026-04-16", amount: 125.25 }
            ]
          }
        }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("inline")
      expect(response.body.bytes.first(4)).to eq([ 0x25, 0x50, 0x44, 0x46 ])
    end

    it "rejects oversized official form field overrides" do
      post "/api/v1/admin/reports/quarterly_compliance_packet_official_form_preview",
        params: {
          year: 2026,
          quarter: 2,
          form_type: "w1",
          fields: {
            company_name: "A" * 251,
            daily_liabilities: [
              { pay_date: "2026-04-16", amount: 125.25 }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("longer than")
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

      expect(employee_row["box1_wages_tips_other_comp"].to_f).to eq(3000.0)
      expect(employee_row["box2_federal_income_tax_withheld"].to_f).to eq(250.0)
      expect(employee_row["box3_social_security_wages"].to_f).to eq(2900.0)
      expect(employee_row["box4_social_security_tax_withheld"].to_f).to eq(186.0)
      expect(employee_row["box5_medicare_wages_tips"].to_f).to eq(3000.0)
      expect(employee_row["box6_medicare_tax_withheld"].to_f).to eq(43.5)
      expect(employee_row["box7_social_security_tips"].to_f).to eq(100.0)

      expect(totals["box1_wages_tips_other_comp"].to_f).to eq(3000.0)
      expect(totals["box2_federal_income_tax_withheld"].to_f).to eq(250.0)
      expect(totals["box3_social_security_wages"].to_f).to eq(2900.0)
      expect(totals["box4_social_security_tax_withheld"].to_f).to eq(186.0)
      expect(totals["box5_medicare_wages_tips"].to_f).to eq(3000.0)
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
      employee.update_columns(address_line1: nil, city: nil, state: nil, zip: nil)

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
        gross_pay: 250_000.00,
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
      allow(Date).to receive(:current).and_return(Date.new(2025, 6, 1))

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
      expect(csv_body).to include("3000.00")
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
      allow(Date).to receive(:current).and_return(Date.new(2025, 6, 1))

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
      allow(Date).to receive(:current).and_return(Date.new(2025, 6, 1))

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
    let(:year_without_committed_payroll) { Date.current.year + 1 }

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

      filing = response.parsed_body["filing"]
      expect(filing).to be_a(Hash)
      expect(filing["status"]).to eq("preflight_passed")
      expect(filing["blocking_count"]).to eq(0)
      expect(filing["preflight_run_at"]).to be_present
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

    it "returns blocking finding when selected year has no committed payroll" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: year_without_committed_payroll }

      expect(response).to have_http_status(:ok)
      preflight = response.parsed_body["preflight"]
      finding = preflight["findings"].find { |f| f["code"] == "NO_COMMITTED_PAYROLL" }
      expect(finding).to be_present
      expect(finding["severity"]).to eq("blocking")
      expect(preflight["blocking_count"]).to be >= 1
    end

    it "flags missing employer EIN as blocking finding" do
      company.update!(ein: nil)

      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      preflight = response.parsed_body["preflight"]
      finding = preflight["findings"].find { |f| f["code"] == "EMPLOYER_EIN_MISSING" }
      expect(finding).to be_present
      expect(finding["severity"]).to eq("blocking")
    end

    it "flags incomplete employer address as blocking finding" do
      company.update!(address_line1: nil)

      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      preflight = response.parsed_body["preflight"]
      finding = preflight["findings"].find { |f| f["code"] == "EMPLOYER_ADDRESS_INCOMPLETE" }
      expect(finding).to be_present
      expect(finding["severity"]).to eq("blocking")
    end

    it "returns 422 for invalid year" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: "bad" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/year/i)
    end
  end

  describe "GET /api/v1/admin/reports/w2_gu_filing_readiness" do
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

    it "returns nil when no readiness row exists for year" do
      get "/api/v1/admin/reports/w2_gu_filing_readiness", params: { year: 2025 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["filing"]).to be_nil
    end

    it "returns persisted readiness for year" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }
      expect(response).to have_http_status(:ok)

      get "/api/v1/admin/reports/w2_gu_filing_readiness", params: { year: 2025 }
      expect(response).to have_http_status(:ok)
      filing = response.parsed_body["filing"]
      expect(filing["status"]).to eq("preflight_passed")
      expect(filing["blocking_count"]).to eq(0)
      expect(filing["findings_source"]).to eq("persisted")
    end
  end

  describe "POST /api/v1/admin/reports/w2_gu_mark_ready" do
    let(:year_without_committed_payroll) { Date.current.year + 1 }

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

    it "returns 422 when selected year has no committed payroll" do
      post "/api/v1/admin/reports/w2_gu_preflight", params: { year: year_without_committed_payroll }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("preflight", "findings").any? { |f| f["code"] == "NO_COMMITTED_PAYROLL" }).to eq(true)

      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: year_without_committed_payroll }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/blocking findings/i)
    end

    it "marks filing ready when no blocking findings" do
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025, notes: "Reviewed by ops" }
      expect(response).to have_http_status(:ok)
      filing = response.parsed_body["filing"]
      expect(filing["status"]).to eq("filing_ready")
      expect(filing["notes"]).to eq("Reviewed by ops")
      expect(filing["marked_ready_at"]).to be_present
      expect(filing["marked_ready_by_id"]).to eq(admin_user.id)
      expect(filing["findings_source"]).to eq("persisted")
      expect(response.parsed_body.dig("revalidation", "year")).to eq(2025)
      expect(response.parsed_body.dig("revalidation", "company_id")).to eq(company.id)
      expect(response.parsed_body.dig("revalidation", "company_name")).to eq(company.name)
      expect(response.parsed_body.dig("revalidation", "findings_source")).to eq("revalidation")
      expect(response.parsed_body.dig("revalidation", "warning_count")).to be_a(Integer)
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
      expect(response.parsed_body.dig("filing", "findings_source")).to eq("persisted")
      expect(response.parsed_body.dig("revalidation", "findings_source")).to eq("revalidation")
      expect(response.parsed_body.dig("revalidation", "findings")).to be_an(Array)
      expect(response.parsed_body.dig("revalidation", "findings").any? { |f| f["code"] == "EMPLOYEE_SSN_MISSING" }).to eq(true)

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
      expect(updated.preflight_run_at).to eq(preflight_run_at)
      expect(updated.status).to eq("filing_ready")
    end

    it "does not overwrite persisted findings/warnings during mark_ready revalidation" do
      filing = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      persisted_findings = filing.findings
      persisted_warning_count = filing.warning_count

      employee.update!(ssn_encrypted: nil)
      post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
      expect(response).to have_http_status(:unprocessable_entity)

      updated = W2FilingReadiness.find_by!(company_id: company.id, year: 2025)
      expect(updated.findings).to eq(persisted_findings)
      expect(updated.warning_count).to eq(persisted_warning_count)
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

  describe "custom earning and deduction report visibility" do
    let!(:pay_period) do
      create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 18))
    end

    before do
      EmployeeYtdTotal.create!(
        employee: employee,
        year: 2026,
        gross_pay: 1_250.00,
        withholding_tax: 100.00,
        social_security_tax: 77.50,
        medicare_tax: 18.13,
        retirement: 40.00,
        net_pay: 974.37)

      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        gross_pay: 1_250.00,
        net_pay: 974.37,
        withholding_tax: 100.00,
        social_security_tax: 77.50,
        medicare_tax: 18.13,
        retirement_payment: 40.00,
        total_deductions: 275.63,
        custom_earnings: [ { "label" => "Certification Pay", "amount" => 50.00 } ],
        custom_deductions: [ { "label" => "Cash Advance", "amount" => 40.00 } ])
    end

    it "surfaces custom totals in YTD summary reports" do
      get "/api/v1/admin/reports/ytd_summary", params: { year: 2026 }

      expect(response).to have_http_status(:ok)
      report = response.parsed_body.fetch("report")
      employee_row = report.fetch("employees").find { |row| row.fetch("employee_id") == employee.id }

      expect(employee_row.fetch("custom_earnings_total").to_f).to eq(50.00)
      expect(employee_row.fetch("custom_deductions_total").to_f).to eq(40.00)
      expect(employee_row.fetch("total_deductions").to_f).to eq(275.63)
      expect(report.dig("company_totals", "custom_earnings_total").to_f).to eq(50.00)
      expect(report.dig("company_totals", "custom_deductions_total").to_f).to eq(40.00)
    end

    it "surfaces custom totals in employee pay history reports" do
      get "/api/v1/admin/reports/employee_pay_history", params: { employee_id: employee.id }

      expect(response).to have_http_status(:ok)
      report = response.parsed_body.fetch("report")

      expect(report.dig("history", 0, "custom_earnings_total").to_f).to eq(50.00)
      expect(report.dig("history", 0, "custom_deductions_total").to_f).to eq(40.00)
      expect(report.dig("ytd", "custom_earnings_total").to_f).to eq(50.00)
      expect(report.dig("ytd", "custom_deductions_total").to_f).to eq(40.00)
      expect(report.dig("ytd", "total_deductions").to_f).to eq(275.63)
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

    it "does not double-count mirrored payroll field employer contributions in JSON" do
      item = pay_period.payroll_items.first
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Employer Health",
        kind: "employer_contribution",
        tax_treatment: "employer_contribution",
        category: "insurance"
      )
      [45.0, 60.0].each_with_index do |amount, index|
        item.payroll_item_field_entries.create!(
          payroll_field_definition: index.zero? ? field : nil,
          label: "Employer Health",
          kind: "employer_contribution",
          tax_treatment: "employer_contribution",
          category: "insurance",
          amount: amount,
          source: "manual",
          employee_paid: false,
          employer_paid: true
        )
        deduction_type = DeductionType.create!(
          company: company,
          name: "Payroll Field Employer Health #{index}",
          category: "employer_contribution",
          sub_category: "insurance"
        )
        item.payroll_item_deductions.create!(
          deduction_type: deduction_type,
          label: "Employer Health",
          category: "employer_contribution",
          amount: amount
        )
      end

      get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: pay_period.id }

      row = response.parsed_body["report"]["employees"].first
      contribution_rows = row["employer_contributions_breakdown"].select { |entry| entry["label"] == "Employer Health" }
      expect(contribution_rows.map { |entry| entry["amount"].to_f }).to contain_exactly(45.0, 60.0)
      expect(contribution_rows).to all(include("deduction_type" => "Payroll Field"))
    end

    it "includes payroll field columns and amounts" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      pay_period.payroll_items.first.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 75.00,
        source: "manual"
      )

      get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: pay_period.id }

      first_line = response.body.lines.first
      expect(first_line).to include("Payroll Field - Rent Deduction (Post tax deduction)")
      expect(response.body).to include("75.00")
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
      allow(Date).to receive(:current).and_return(Date.new(2025, 6, 1))

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
      allow(Date).to receive(:current).and_return(Date.new(2025, 6, 1))

      get "/api/v1/admin/reports/tax_summary_pdf"

      expect(response).to have_http_status(:ok)
    end

    it "includes quarter filter in filename when quarter is provided" do
      get "/api/v1/admin/reports/tax_summary_pdf", params: { year: 2025, quarter: 2 }

      disposition = response.headers["Content-Disposition"]
      expect(disposition).to include("q2")
    end
  end

  describe "GET /api/v1/admin/reports/installment_loans_pdf" do
    it "returns 422 for an invalid as_of_date" do
      get "/api/v1/admin/reports/installment_loans_pdf", params: { as_of_date: "notadate" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invalid as_of_date - expected YYYY-MM-DD")
    end
  end

  describe "installment loans Excel sheets" do
    it "uses the as_of_date for transaction filtering and balance snapshots" do
      loan = EmployeeLoan.create!(
        employee: employee,
        company: company,
        name: "Travel Advance",
        original_amount: 300.00,
        current_balance: 100.00,
        payment_amount: 50.00,
        start_date: Date.new(2026, 1, 1),
        status: "active"
      )
      loan.loan_transactions.create!(
        transaction_type: "addition",
        amount: 300.00,
        balance_before: 0.00,
        balance_after: 300.00,
        transaction_date: Date.new(2026, 1, 1)
      )
      loan.loan_transactions.create!(
        transaction_type: "payment",
        amount: 100.00,
        balance_before: 300.00,
        balance_after: 200.00,
        transaction_date: Date.new(2026, 2, 1)
      )
      loan.loan_transactions.create!(
        transaction_type: "payment",
        amount: 100.00,
        balance_before: 200.00,
        balance_after: 100.00,
        transaction_date: Date.new(2026, 4, 1)
      )

      sheets = Api::V1::Admin::ReportsController.new.send(:installment_loans_sheets, company, as_of_date: Date.new(2026, 3, 1))
      rows = sheets.first.fetch(:rows)

      expect(rows.first).to include("Balance As Of", "As Of Date")
      expect(rows.size).to eq(3)
      expect(rows.last).to include(Date.new(2026, 3, 1), Date.new(2026, 2, 1), "payment", 200.00)
      expect(rows.flatten).not_to include(Date.new(2026, 4, 1))
    end
  end

  describe "payroll summary by employee Excel sheets" do
    it "uses a summary-specific workbook instead of payroll register sheets" do
      report = {
        summary: {
          employee_count: 1,
          total_gross: 1_000.00,
          total_reported_tips: 50.00,
          total_tips_paid_out: 25.00,
          total_bonus: 10.00,
          total_custom_earnings: 20.00,
          total_custom_deductions: 12.00,
          total_withholding: 100.00,
          total_social_security: 62.00,
          total_medicare: 14.50,
          total_traditional_retirement: 40.00,
          total_roth_retirement: 30.00,
          total_employer_traditional_retirement: 20.00,
          total_employer_roth_retirement: 15.00,
          total_deductions: 246.50,
          total_net: 753.50
        },
        employees: [
          {
            employee_last_name: "Terlaje",
            employee_first_name: "Mina",
            employee_name: "Mina Terlaje",
            employment_type: "hourly",
            gross_pay: 1_000.00,
            reported_tips: 50.00,
            tips_paid_out: 25.00,
            bonus: 10.00,
            custom_earnings_total: 20.00,
            custom_deductions_total: 12.00,
            withholding_tax: 100.00,
            social_security_tax: 62.00,
            medicare_tax: 14.50,
            retirement_payment: 40.00,
            roth_retirement_payment: 30.00,
            loan_deduction: 0.00,
            insurance_payment: 0.00,
            total_deductions: 246.50,
            net_pay: 753.50,
            employer_social_security_tax: 62.00,
            employer_medicare_tax: 14.50,
            employer_retirement_match: 20.00,
            employer_roth_retirement_match: 15.00
          }
        ],
        contractors: [
          {
            employee_last_name: "Santos",
            employee_first_name: "Kai",
            employee_name: "Kai Santos",
            employment_type: "contractor",
            gross_pay: 600.00,
            reported_tips: 0.00,
            tips_paid_out: 0.00,
            bonus: 0.00,
            custom_earnings_total: 75.00,
            custom_deductions_total: 0.00,
            withholding_tax: 0.00,
            social_security_tax: 0.00,
            medicare_tax: 0.00,
            retirement_payment: 0.00,
            roth_retirement_payment: 0.00,
            loan_deduction: 0.00,
            insurance_payment: 0.00,
            total_deductions: 0.00,
            net_pay: 600.00,
            employer_social_security_tax: 0.00,
            employer_medicare_tax: 0.00,
            employer_retirement_match: 0.00,
            employer_roth_retirement_match: 0.00
          }
        ]
      }

      sheets = Api::V1::Admin::ReportsController.new.send(:payroll_summary_by_employee_sheets, report)

      expect(sheets.map { |sheet| sheet[:name] }).to include("Employee Summary", "Totals", "Contractor Summary", "Contractor Totals")
      expect(sheets.first[:rows].first).to include("Total Payroll Cost")
      expect(sheets.first[:rows].first).not_to include("Check Number", "Check Date")
      expect(sheets.first[:rows].last).to include("Mina Terlaje", 1_000.00, 1_111.50)
      expect(sheets.second[:rows]).to include([ "Roth 401(k)", 30.00 ])
      contractor_totals = sheets.find { |sheet| sheet[:name] == "Contractor Totals" }
      expect(contractor_totals[:rows]).to include([ "Contractors", 1 ])
      expect(contractor_totals[:rows]).to include([ "Gross Pay", 600.00 ])
      expect(contractor_totals[:rows]).to include([ "Custom Earnings", 75.00 ])
      expect(contractor_totals[:rows]).to include([ "Net Pay", 600.00 ])
    end
  end

  describe "GET /api/v1/admin/reports/form_1099_nec_xlsx" do
    it "returns 422 for a non-numeric year" do
      get "/api/v1/admin/reports/form_1099_nec_xlsx", params: { year: "not-a-year" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("year must be a valid 4-digit tax year")
    end
  end

  describe "filing workbook report info sheets" do
    it "includes client and generated-at metadata for 941-GU, W-2GU, and 1099-NEC sheets" do
      controller = Api::V1::Admin::ReportsController.new
      generated_at = "2026-04-30T12:00:00Z"
      meta = { company_name: company.name, generated_at: generated_at }

      reports = [
        controller.send(:form_941_gu_sheets, {
          meta: meta,
          lines: {},
          tax_detail: {},
          monthly_liability: []
        }),
        controller.send(:w2_gu_sheets, {
          "meta" => meta.stringify_keys,
          "employer" => { "name" => company.name },
          employees: [],
          totals: {}
        }),
        controller.send(:form_1099_nec_sheets, {
          "meta" => meta.stringify_keys,
          "payer" => { "name" => company.name },
          reportable_contractors: [],
          totals: {}
        })
      ]

      reports.each do |sheets|
        rows = sheets.find { |sheet| sheet[:name] == "Report Info" }.fetch(:rows)
        expect(rows).to include([ "Client", company.name ])
        expect(rows).to include([ "Generated At", generated_at ])
      end
    end
  end

  describe "employee pay history Excel sheets" do
    it "uses human-readable labels for the YTD worksheet" do
      sheets = Api::V1::Admin::ReportsController.new.send(:employee_pay_history_sheets, {
        history: [],
        ytd: {
          year: 2026,
          gross_pay: 1_000.00,
          withholding_tax: 100.00,
          social_security_tax: 62.00,
          medicare_tax: 14.50,
          retirement: 50.00,
          roth_retirement: 25.00,
          tips: 20.00,
          tips_paid_out: 15.00,
          bonus: 10.00,
          custom_earnings_total: 20.00,
          total_deductions: 261.50,
          custom_deductions_total: 15.00,
          net_pay: 738.50
        }
      })

      history_header = sheets.first.fetch(:rows).first
      expect(history_header).to include("Custom Earnings", "Custom Deductions")

      ytd_rows = sheets.fetch(1).fetch(:rows)
      expect(ytd_rows).to include([ "Metric", "Amount" ])
      expect(ytd_rows).to include([ "Gross Pay", 1_000.00 ])
      expect(ytd_rows).to include([ "Custom Earnings", 20.00 ])
      expect(ytd_rows).to include([ "401(k)", 50.00 ])
      expect(ytd_rows).to include([ "Roth 401(k)", 25.00 ])
      expect(ytd_rows).to include([ "Total Deductions", 261.50 ])
      expect(ytd_rows).to include([ "Custom Deductions", 15.00 ])
      expect(ytd_rows.flatten).not_to include(:gross_pay, :roth_retirement)
    end
  end
end
