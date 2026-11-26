# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Report argument error handling", type: :request do
  include HistoricalYtdBridgeFixtureHelper

  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "reports-errors-admin@example.com") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "reports-errors-client@example.com") }

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Client::ReportsController).to receive(:current_user).and_return(client_user)
  end

  it "returns intentional ReportValidationError messages on admin and client endpoints" do
    get "/api/v1/admin/reports/ytd_summary", params: { year: 2026, pay_run_key: "invalid" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "pay_run_key must use native:<id> or imported:<id>")

    get "/api/v1/admin/reports/employee_pay_history", params: { employee_id: employee.id, limit: 999 }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "limit must be between 1 and 120")

    get "/api/v1/admin/reports/quarterly_compliance_packet_official_form_defaults",
      params: { year: 2026, quarter: 1, form_type: "unknown_form" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "form_type must be form_941, schedule_b, w1, or swica")

    get "/api/v1/client/reports/ytd_summary", params: { year: 2026, pay_run_key: "invalid" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "pay_run_key must use native:<id> or imported:<id>")
  end

  it "returns the staff-actionable 401(k) contribution-type review message on w2_gu" do
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    bootstrap = create(:historical_client_bootstrap, company: company, historical_import_batch: batch, status: "applied")
    period = HistoricalPayPeriod.create!(
      company: company,
      historical_import_batch: batch,
      external_key: "w2-review-period",
      source_label: "Payroll Mar 2026",
      period_type: "regular",
      start_date: Date.new(2026, 3, 15),
      end_date: Date.new(2026, 3, 31),
      pay_date: Date.new(2026, 4, 3),
      paycheck_count: 1,
      totals: { "gross_pay" => "5000.00", "net_pay" => "4000.00" }
    )
    worker = HistoricalWorker.create!(
      company: company,
      historical_import_batch: batch,
      employee: employee,
      external_key: "w2-review-worker",
      source_name: employee.full_name,
      normalized_name: employee.full_name.downcase,
      source_status: "active",
      mapping_status: "exact_match"
    )
    HistoricalPaycheck.create!(
      company: company,
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      employee: employee,
      external_key: "w2-review-check",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      gross_pay: 5_000,
      adjusted_gross: 5_000,
      net_pay: 4_000
    )
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: SecureRandom.hex(16),
      applied_at: Time.current,
      applied_by: admin_user,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
      preview_summary: {
        "through_period_end" => "2026-03-31",
        "through_pay_date" => "2026-04-03",
        "adjustment_digest" => HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest
      }
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: 2026,
      through_period_end: Date.new(2026, 3, 31),
      through_pay_date: Date.new(2026, 4, 3),
      gross_pay: 5_000,
      fit_taxable_wages: 4_800,
      social_security_taxable_wages: 5_000,
      medicare_taxable_wages: 5_000,
      retirement: 0,
      source_breakdown: { "pretax_deduction_breakdown" => { "401(k) After Tax" => "200.00" } }
    )

    get "/api/v1/admin/reports/w2_gu", params: { year: 2026 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include(HistoricalRetirementProjection::REVIEW_MESSAGE)
    expect(response.parsed_body["error"]).to include("No complete contribution-type review is recorded for 2026.")
  end

  it "returns specific ReportValidationError messages for missing 1099 thresholds and invalid quarters" do
    get "/api/v1/admin/reports/form_1099_nec", params: { year: 2027 }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "No 1099_nec reporting threshold is configured for 2027")

    get "/api/v1/admin/reports/form_941_gu", params: { year: 2026, quarter: 5 }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "quarter is required and must be 1, 2, 3, or 4")

    get "/api/v1/admin/reports/quarterly_compliance_packet", params: { year: 2026, quarter: 5 }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "quarter is required and must be 1, 2, 3, or 4")

    expect { PayrollFilingResponsibilityGate.filing_range(tax_year: 2026, quarter: 5) }
      .to raise_error(ReportValidationError, "quarter must be 1, 2, 3, or 4")
  end

  it "masks unexpected ArgumentError on admin report actions and logs plus reports it" do
    error = ArgumentError.new("unexpected internal detail: bucket mismatch")
    allow_any_instance_of(UnifiedPayrollReporting).to receive(:historical_paychecks).and_raise(error)
    expect(Rails.logger).to receive(:error).with(/Report ytd_summary for company #{company.id}: ArgumentError/)
    expect(Rails.error).to receive(:report).with(error, handled: true, context: {
      company_id: company.id, report: "ytd_summary"
    }).and_call_original

    get "/api/v1/admin/reports/ytd_summary", params: { year: 2026 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "We couldn't prepare this report. Try again or contact support.")
  end

  it "masks unexpected ArgumentError on quarterly_compliance_packet_official_form_defaults" do
    error = ArgumentError.new("unexpected form default crash")
    allow_any_instance_of(Api::V1::Admin::ReportsController)
      .to receive(:quarterly_compliance_official_form_defaults).and_raise(error)
    expect(Rails.logger).to receive(:error).with(/Report quarterly_compliance_packet_official_form_defaults for company #{company.id}: ArgumentError/)
    expect(Rails.error).to receive(:report).with(error, handled: true, context: {
      company_id: company.id, report: "quarterly_compliance_packet_official_form_defaults"
    }).and_call_original

    get "/api/v1/admin/reports/quarterly_compliance_packet_official_form_defaults",
      params: { year: 2026, quarter: 1, form_type: "w1" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "We couldn't prepare this report. Try again or contact support.")
  end

  it "masks unexpected ArgumentError on inherited client report endpoints" do
    error = ArgumentError.new("raw internal calculator bug")
    allow_any_instance_of(Form941GuAggregator).to receive(:generate).and_raise(error)
    expect(Rails.logger).to receive(:error).with(/Report form_941_gu for company #{company.id}: ArgumentError/)
    expect(Rails.error).to receive(:report).with(error, handled: true, context: {
      company_id: company.id, report: "form_941_gu"
    }).and_call_original

    get "/api/v1/client/reports/form_941_gu", params: { year: 2026, quarter: 1 }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "We couldn't prepare this report. Try again or contact support.")
  end
end
