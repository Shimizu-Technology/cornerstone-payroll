# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Training replay benchmark comparison", type: :request do
  let(:organization) { create(:organization) }
  let(:source_company) { create(:company, organization: organization) }
  let(:admin) { create(:user, company: source_company, organization: organization, role: "admin") }
  let(:source_employee) { create(:employee, company: source_company, department: nil) }
  let(:source_period) do
    create(
      :pay_period,
      :committed,
      company: source_company,
      start_date: Date.new(2026, 9, 5),
      end_date: Date.new(2026, 9, 18),
      pay_date: Date.new(2026, 9, 25)
    )
  end
  let(:target_company) do
    create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "training_replay",
      migration_source_company: source_company,
      migration_rehearsal_status: "ready"
    )
  end
  let(:target_employee) do
    create(
      :employee,
      company: target_company,
      department: nil,
      test_workspace_source_employee: source_employee
    )
  end
  let(:practice_period) do
    create(
      :pay_period,
      company: target_company,
      start_date: source_period.start_date,
      end_date: source_period.end_date,
      pay_date: source_period.pay_date,
      test_workspace_role: "practice",
      test_workspace_source_pay_period: source_period
    )
  end

  before do
    create(
      :payroll_item,
      company: source_company,
      pay_period: source_period,
      employee: source_employee,
      gross_pay: 1_000,
      net_pay: 800
    )
    create(
      :payroll_item,
      company: target_company,
      pay_period: practice_period,
      employee: target_employee,
      gross_pay: 0,
      net_pay: 0
    )
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(target_company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin.id)
  end

  it "reveals the live benchmark only after the practice payroll is calculated" do
    get "/api/v1/admin/pay_periods/#{practice_period.id}/comparison"

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Calculate this practice payroll")

    practice_period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: admin.id)
    get "/api/v1/admin/pay_periods/#{practice_period.id}/comparison"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("comparison_kind" => "training_benchmark")
    expect(response.parsed_body.dig("previous_pay_period", "id")).to eq(source_period.id)
  end
end
