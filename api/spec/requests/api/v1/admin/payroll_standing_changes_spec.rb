# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Every-period client change settings", type: :request do
  let!(:company) { create(:company) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
  let(:url) { "/api/v1/admin/payroll_standing_changes" }
  before { stub_portal_user(Api::V1::Admin::PayrollStandingChangesController, staff, company) }

  it "creates, lists, edits and deactivates scoped defaults with audit identity" do
    post url, params: { standing_change: { kind: "owner_pay", employee_id: owner.id, position: 0 } }, as: :json
    expect(response).to have_http_status(:created), response.body
    id = response.parsed_body.fetch("defaults").sole.fetch("id")
    patch "#{url}/#{id}", params: { standing_change: { position: 2 } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    patch "#{url}/#{id}", params: { standing_change: { active: false } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(PayrollStandingChange.find(id)).not_to be_active
    expect(AuditLog.where(record_type: "PayrollStandingChange", record_id: id).last).to have_attributes(company_id: company.id)
  end

  it "rejects foreign employees, foreign defaults and unsupported kinds" do
    post url, params: { standing_change: { kind: "owner_pay", employee_id: create(:employee).id } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch "#{url}/999999999", params: { standing_change: { active: false } }, as: :json
    expect(response).to have_http_status(:not_found)
    post url, params: { standing_change: { kind: "new_hire", employee_id: owner.id } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "refuses clients and accountants without configuration rights" do
    staff.update!(role: "client")
    post url, params: { standing_change: { kind: "owner_pay", employee_id: owner.id } }, as: :json
    expect(response).to have_http_status(:forbidden)
    staff.update!(role: "accountant")
    post url, params: { standing_change: { kind: "owner_pay", employee_id: owner.id } }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(PayrollStandingChange.count).to eq(0)
  end
  it "allows a delegated accountant with configuration rights and records their identity" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    create(:company_assignment, company: company, user: accountant, client_management: true, granted_by: staff)
    stub_portal_user(Api::V1::Admin::PayrollStandingChangesController, accountant, company)
    post url, params: { standing_change: { kind: "owner_pay", employee_id: owner.id } }, as: :json
    expect(response).to have_http_status(:created), response.body
    log = AuditLog.find_by!(record_type: "PayrollStandingChange", record_id: response.parsed_body.fetch("defaults").sole.fetch("id"))
    expect(log).to have_attributes(user_id: accountant.id, company_id: company.id)
  end
end
