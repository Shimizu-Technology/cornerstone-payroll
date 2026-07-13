# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollLiabilities", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  before do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      withholding_tax: 100,
      social_security_tax: 50,
      employer_social_security_tax: 50)
    PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: admin_user)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilitiesController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilitiesController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "returns an immutable reconciliation view for the selected company" do
    get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities"

    expect(response).to have_http_status(:ok)
    reconciliation = response.parsed_body.fetch("payroll_liability_reconciliation")
    expect(reconciliation).to include(
      "status" => "posted",
      "company_id" => company.id,
      "pay_period_id" => pay_period.id,
      "net_liability" => 200.0,
      "historical_backfill_required" => false
    )
    expect(reconciliation.fetch("postings").first.fetch("entries")).not_to be_empty
  end

  it "does not expose another company's pay period" do
    other_company = create(:company)
    other_period = create(:pay_period, :committed, company: other_company)

    get "/api/v1/admin/pay_periods/#{other_period.id}/payroll_liabilities"

    expect(response).to have_http_status(:not_found)
  end
end
