# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollGoLive", type: :request do
  let(:organization) { create(:organization) }
  let(:company) do
    create(
      :company,
      organization:,
      ein: "66-1234567",
      address_line1: "123 Marine Corps Drive",
      city: "Tamuning",
      state: "GU",
      zip: "96913"
    )
  end
  let(:source_company) { create(:company, organization:) }
  let(:batch) { create(:historical_import_batch, company:, status: "locked") }
  let(:accountant) { create(:user, company:, organization:, role: "accountant") }
  let!(:review) do
    PayrollGoLiveReview.create!(
      company:,
      source_company:,
      historical_import_batch: batch,
      created_by: accountant,
      effective_on: Date.new(2026, 9, 21),
      plan_digest: "d" * 64,
      status: "setup_applied",
      setup_applied_at: Time.current,
      setup_applied_by: accountant
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollGoLiveController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::PayrollGoLiveController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollGoLiveController).to receive(:current_user).and_return(accountant)
  end

  it "returns field-level company review readiness" do
    get "/api/v1/admin/payroll_go_live"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "company_setup")).to include(
      "status" => "needs_review",
      "current" => false,
      "missing_required_fields" => []
    )
    expect(response.parsed_body.dig("permissions", "can_review_company_setup")).to be(true)
  end

  it "records an accountant's company setup confirmation" do
    post "/api/v1/admin/payroll_go_live/review_company_setup", params: {
      acknowledgement: PayrollCompanySetupReview::ACKNOWLEDGEMENT,
      notes: "Matched the EIN and filing address to the signed employer records."
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "company_setup")).to include(
      "status" => "current",
      "current" => true,
      "reviewed_by_name" => accountant.name
    )
  end

  it "denies a client user without changing company setup review evidence" do
    client = create(:user, company:, organization:, role: "client")
    allow_any_instance_of(Api::V1::Admin::PayrollGoLiveController).to receive(:current_user).and_return(client)

    post "/api/v1/admin/payroll_go_live/review_company_setup", params: {
      acknowledgement: PayrollCompanySetupReview::ACKNOWLEDGEMENT,
      notes: "Attempted review."
    }

    expect(response).to have_http_status(:forbidden)
    expect(review.reload.company_setup_reviewed_at).to be_nil
  end
end
