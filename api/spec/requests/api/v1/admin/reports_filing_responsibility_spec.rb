# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll report filing responsibility gates", type: :request do
  let!(:company) { create(:company, ein: "12-3456789") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(admin)
  end

  def create_native_payroll(pay_date:)
    period = create(
      :pay_period,
      :committed,
      company: company,
      start_date: pay_date - 17.days,
      end_date: pay_date - 3.days,
      pay_date: pay_date
    )
    create(
      :payroll_item,
      company: company,
      employee: employee,
      pay_period: period,
      gross_pay: 3_000,
      net_pay: 2_500,
      withholding_tax: 250,
      social_security_tax: 186,
      employer_social_security_tax: 186,
      medicare_tax: 43.50,
      employer_medicare_tax: 43.50
    )
    period
  end

  def create_historical_period(pay_date:)
    batch = create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: 2.days.ago,
      locked_by: admin
    )
    HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "filing-gate-#{batch.id}",
      source_label: batch.source_label,
      period_type: "regular",
      start_date: pay_date - 17.days,
      end_date: pay_date - 3.days,
      pay_date: pay_date,
      paycheck_count: 1
    )
  end

  it "keeps W-2GU review available but blocks filing-ready status until its annual decision is recorded" do
    create_native_payroll(pay_date: Date.new(2025, 1, 18))
    create_historical_period(pay_date: Date.new(2025, 2, 1))

    get "/api/v1/admin/reports/w2_gu", params: { year: 2025 }

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("report", "filing_gate", "filings", "w2_gu", "blockers", 0, "code"))
      .to eq("PAYROLL_FILING_RESPONSIBILITY_REQUIRED")
    expect(response.parsed_body.dig("report", "filing_gate", "capabilities", "can_review_draft")).to be(true)

    post "/api/v1/admin/reports/w2_gu_preflight", params: { year: 2025 }
    expect(response).to have_http_status(:ok), response.body

    post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("filing_gate", "filings", "w2_gu", "blockers", 0, "code"))
      .to eq("PAYROLL_FILING_RESPONSIBILITY_REQUIRED")

    create(
      :payroll_filing_responsibility,
      :annual,
      company: company,
      reviewed_by: admin,
      tax_year: 2025,
      responsible_party: "cornerstone",
      imported_payroll_inclusion: "included",
      reviewed_at: 1.day.ago
    )

    post "/api/v1/admin/reports/w2_gu_mark_ready", params: { year: 2025 }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("filing", "status")).to eq("filing_ready")
  end

  it "blocks a quarterly task from ready-to-file while preserving draft packet review" do
    create_native_payroll(pay_date: Date.new(2026, 5, 8))
    create_historical_period(pay_date: Date.new(2026, 5, 22))

    post "/api/v1/admin/reports/quarterly_compliance_packet_workflow", params: { year: 2026, quarter: 2 }

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("report", "filing_gate", "blockers")).not_to be_empty
    task = response.parsed_body.dig("report", "workflow", "tasks").find { |row| row.fetch("task_type") == "federal_941" }

    patch "/api/v1/admin/reports/quarterly_compliance_packet_task/#{task.fetch('id')}", params: {
      task: { status: "ready_to_file", notes: "Prepared for reviewer" }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("filing_gate", "blockers", 0, "code"))
      .to eq("PAYROLL_FILING_RESPONSIBILITY_REQUIRED")

    get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 2 }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("report", "filing_gate", "filings", "form_941", "capabilities", "can_review_draft"))
      .to be(true)
  end

  it "blocks an official quarterly download but leaves the inline preview available" do
    create_native_payroll(pay_date: Date.new(2026, 5, 8))
    create_historical_period(pay_date: Date.new(2026, 5, 22))

    post "/api/v1/admin/reports/quarterly_compliance_packet_official_form_download", params: {
      year: 2026,
      quarter: 2,
      form_type: "form_941",
      fields: {}
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/official filing output/)
    expect(response.parsed_body.dig("filing_gate", "blockers", 0, "code"))
      .to eq("PAYROLL_FILING_RESPONSIBILITY_REQUIRED")

    allow_any_instance_of(QuarterlyComplianceOfficialForms::Form941).to receive(:generate).and_return("preview-pdf")
    post "/api/v1/admin/reports/quarterly_compliance_packet_official_form_preview", params: {
      year: 2026,
      quarter: 2,
      form_type: "form_941",
      fields: {}
    }

    expect(response).to have_http_status(:ok), response.body
    expect(response.body).to eq("preview-pdf")
  end
end
