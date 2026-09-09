# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin migration rehearsal safety", type: :request do
  let(:organization) { create(:organization) }
  let(:source_company) { create(:company, organization: organization) }
  let(:source_batch) { create(:historical_import_batch, company: source_company, status: "locked") }
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end
  let(:admin) { create(:user, company: rehearsal, organization: organization, role: "admin") }
  let(:pay_period) do
    create(
      :pay_period,
      company: rehearsal,
      status: "approved",
      start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 14),
      pay_date: Date.new(2026, 8, 21)
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(rehearsal.id)
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_company_id).and_return(rehearsal.id)
  end

  it "blocks commit before any financial finalization occurs" do
    post "/api/v1/admin/pay_periods/#{pay_period.id}/commit"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to include("unavailable in a migration rehearsal")
    expect(pay_period.reload.status).to eq("approved")
  end

  it "blocks saving Form 500 filing state" do
    post "/api/v1/form_500s/save", params: { form_500: { pay_period_id: pay_period.id, status: "paid" } }

    expect(response).to have_http_status(:forbidden)
    expect(Form500Filing.where(pay_period: pay_period)).to be_empty
  end
end
