# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Report argument error handling", type: :request do
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
