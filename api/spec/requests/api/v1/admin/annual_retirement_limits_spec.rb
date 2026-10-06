# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::AnnualRetirementLimits", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company, organization: company.organization, role: :super_admin) }
  let(:path) { "/api/v1/admin/annual_retirement_limits" }
  let(:values) do
    { tax_year: 2099, elective_deferral_limit: 24_500, catch_up_limit: 8000,
      enhanced_catch_up_limit: 11_250, roth_catch_up_wage_threshold: 150_000,
      annual_additions_limit: 72_000, compensation_limit: 360_000,
      source_name: "Synthetic test year", source_url: "https://www.irs.gov/pub/irs-drop/n-25-67.pdf",
      reason: "Synthetic API verification" }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::AnnualRetirementLimitsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AnnualRetirementLimitsController).to receive(:current_user).and_return(user)
  end

  it "creates complete limits with an audit trail" do
    post path, params: { annual_retirement_limit: values }
    expect(response).to have_http_status(:created)
    limit = AnnualRetirementLimit.find_by!(tax_year: 2099)
    expect(limit).to be_complete
    expect(AuditLog.where(action: "annual_retirement_limits#create", record_id: limit.id)).to exist
  end

  it "audits changed values and rejects incomplete updates" do
    post path, params: { annual_retirement_limit: values }
    limit = AnnualRetirementLimit.find_by!(tax_year: 2099)
    patch "#{path}/#{limit.id}", params: { annual_retirement_limit: values.merge(elective_deferral_limit: 24_600) }
    expect(response).to have_http_status(:ok)
    log = AuditLog.find_by!(action: "annual_retirement_limits#update", record_id: limit.id)
    expect(log.metadata.dig("before_values", "elective_deferral_limit").to_f).to eq(24_500)
    patch "#{path}/#{limit.id}", params: { annual_retirement_limit: values.merge(compensation_limit: nil) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(limit.reload.compensation_limit).to eq(360_000)
  end

  it "requires an IRS source and a change reason" do
    post path, params: { annual_retirement_limit: values.merge(source_url: "https://example.org/limits") }
    expect(response).to have_http_status(:unprocessable_entity)
    post path, params: { annual_retirement_limit: values.except(:reason) }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "allows staff to read but prevents organization admins from changing shared limits" do
    user.update!(role: :org_admin)
    get path
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("can_manage")).to be(false)
    post path, params: { annual_retirement_limit: values }
    expect(response).to have_http_status(:forbidden)
  end
end
