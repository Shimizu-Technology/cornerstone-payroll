# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Expected payroll entries", type: :request do
  let(:company) { create(:company) }
  let(:staff) { create(:user, company: company, role: "accountant") }
  let(:period) { create(:pay_period, company: company) }
  let(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
  let(:field) { PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay", label: "Owner amount") }
  let(:url) { "/api/v1/admin/pay_periods/#{period.id}/entry_resolutions" }
  before { ensure_verified_test_tax_years(2024) }
  before { stub_portal_user(Api::V1::Admin::PayrollEntryResolutionsController, staff, company) }

  it "saves and reverses none with actor audit identity" do
    post url, params: { payroll_standing_change_id: field.id, note: "Away" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("expected_entries", "fields").sole).to include("status" => "none")
    expect(AuditLog.where(action: "payroll_entry_resolutions#save").last.user_id).to eq(staff.id)
    delete url, params: { employee_id: owner.id, payroll_standing_change_id: field.id }, as: :json
    expect(response).to have_http_status(:ok)
    expect(PayrollEntryResolution.count).to eq(0)
  end

  it "replaces an old none answer after the field maps to a different employee" do
    post url, params: { payroll_standing_change_id: field.id }, as: :json
    replacement = create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0)
    field.update!(employee: replacement)
    expect(PayrollExpectedEntries.new(period).payload[:outstanding]).to eq([ "Owner amount" ])
    post url, params: { payroll_standing_change_id: field.id, note: "Confirmed for replacement" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(PayrollEntryResolution.where(pay_period: period).sole.employee).to eq(replacement)
  end

  it "fills owner pay using the existing calculation path and returns saved panel status" do
    field
    stub_portal_user(Api::V1::Admin::PayPeriodsController, staff, company)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
      params: { employee_ids: [ owner.id ], salary_overrides: { owner.id.to_s => 850 } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(period.payroll_items.find_by!(employee: owner).salary_override).to eq(850)
    expect(response.parsed_body.dig("pay_period", "expected_entries", "fields").sole).to include("status" => "filled", "value" => "850.0")
  end

  it "rejects foreign employees, clients, disallowed none, and locked periods" do
    post url, params: { employee_id: create(:employee).id }, as: :json
    expect(response).to have_http_status(:not_found)
    field.update!(allow_none: false)
    post url, params: { payroll_standing_change_id: field.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    period.update!(status: "approved")
    post url, params: { employee_id: owner.id }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    staff.update!(role: "client")
    post url, params: { employee_id: owner.id }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
