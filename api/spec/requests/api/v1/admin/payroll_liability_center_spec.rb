# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollLiabilityCenter", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company:) }
  let!(:employee) { create(:employee, company:, department:) }
  let!(:admin_user) { create(:user, company:, organization: company.organization, role: "admin") }
  let!(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:item) do
    create(:payroll_item, company:, employee:, pay_period: period,
      withholding_tax: 100, social_security_tax: 62, employer_social_security_tax: 62)
  end
  let!(:posting) { PayrollLiabilityPostingService.post!(pay_period: period, actor: admin_user) }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilityCenterController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilityCenterController)
      .to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilityCenterController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "returns the company liability worksheet" do
    get "/api/v1/admin/payroll_liability_center", as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch("payroll_liability_center")
    expect(body.dig("totals", "calculated_amount")).to eq(224.0)
    expect(body.fetch("obligations").map { |row| row.fetch("authority") }).to contain_exactly(
      PayrollLiabilityPostingService::GUAM_DRT,
      PayrollLiabilityPostingService::US_TREASURY
    )
  end

  it "stores a reviewed due date only for a real current-company obligation" do
    post "/api/v1/admin/payroll_liability_center/due_date", params: {
      payroll_liability_obligation: {
        pay_period_id: period.id,
        authority: PayrollLiabilityPostingService::GUAM_DRT,
        due_date: "2026-09-15"
      }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(PayrollLiabilityObligationDueDate.last).to have_attributes(
      company_id: company.id,
      pay_period_id: period.id,
      updated_by_id: admin_user.id,
      due_date: Date.new(2026, 9, 15)
    )

    post "/api/v1/admin/payroll_liability_center/due_date", params: {
      payroll_liability_obligation: {
        pay_period_id: period.id,
        authority: "Invented recipient",
        due_date: "2026-09-15"
      }
    }, as: :json
    expect(response).to have_http_status(:not_found)
  end
end
