# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PromotedPaymentIssuance", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:admin) { create(:user, company: company, organization: organization, role: "admin") }
  let(:pay_period) { create(:pay_period, company: company, status: "committed") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
  end

  it "returns the admin-only read-only payment preparation preview" do
    service = instance_double(MigrationPromotion::PreparePaymentIssuance, preview: { eligible: true, paper_check_count: 49 })
    expect(MigrationPromotion::PreparePaymentIssuance).to receive(:new).with(
      pay_period: pay_period,
      actor: admin
    ).and_return(service)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/promoted_payment_preview"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("promoted_payment")).to include("eligible" => true, "paper_check_count" => 49)
  end

  it "passes the attested check controls to the protected preparation service" do
    service = instance_double(
      MigrationPromotion::PreparePaymentIssuance,
      call: { eligible: true, paper_check_count: 49, already_prepared: false }
    )
    expect(MigrationPromotion::PreparePaymentIssuance).to receive(:new).with(
      pay_period: pay_period,
      actor: admin,
      acknowledgement: MigrationPromotion::PreparePaymentIssuance::ACKNOWLEDGEMENT,
      starting_check_number: "7201",
      check_date: "2026-09-24",
      ip_address: kind_of(String)
    ).and_return(service)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/prepare_promoted_payment", params: {
      acknowledgement: MigrationPromotion::PreparePaymentIssuance::ACKNOWLEDGEMENT,
      starting_check_number: "7201",
      check_date: "2026-09-24"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("promoted_payment")).to include(
      "paper_check_count" => 49,
      "already_prepared" => false
    )
  end

  %w[manager accountant].each do |role|
    it "does not allow a #{role} to prepare a promoted payroll for payment" do
      staff = create(:user, company: company, organization: organization, role: role)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(staff)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(staff.id)

      get "/api/v1/admin/pay_periods/#{pay_period.id}/promoted_payment_preview"
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Admin access required")

      post "/api/v1/admin/pay_periods/#{pay_period.id}/prepare_promoted_payment", params: {
        acknowledgement: MigrationPromotion::PreparePaymentIssuance::ACKNOWLEDGEMENT,
        starting_check_number: "7201",
        check_date: "2026-09-24"
      }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
