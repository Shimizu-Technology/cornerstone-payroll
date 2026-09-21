# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::MigrationPromotions", type: :request do
  let(:organization) { create(:organization) }
  let(:target_company) { create(:company, organization: organization, name: "Clean Migration") }
  let(:admin) { create(:user, company: target_company, organization: organization, role: "admin") }
  let(:source_batch) { create(:historical_import_batch, company: target_company, status: "locked") }
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      name: "Migration Test",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "migration_rehearsal",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(admin.id)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(target_company.id)
  end

  it "lets an organization administrator preview the exact rehearsal promotion" do
    preview = instance_double(MigrationPromotion::Preview, call: { ready_to_apply: false, blockers: [ "Create a backup" ] })
    allow(MigrationPromotion::Preview).to receive(:new).with(rehearsal: rehearsal).and_return(preview)

    get "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion_preview"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("migration_promotion")).to include(
      "ready_to_apply" => false,
      "blockers" => [ "Create a backup" ]
    )
  end

  it "passes the backup acknowledgement through the protected service" do
    backup = create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "backup_snapshot",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "pending"
    )
    creator = instance_double(MigrationPromotion::CreateBackup, call: backup)
    expect(MigrationPromotion::CreateBackup).to receive(:new).with(
      rehearsal: rehearsal,
      actor: admin,
      acknowledgement: MigrationPromotion::CreateBackup::ACKNOWLEDGEMENT
    ).and_return(creator)

    post "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion_backup", params: {
      acknowledgement: MigrationPromotion::CreateBackup::ACKNOWLEDGEMENT
    }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("company", "test_workspace_purpose")).to eq("backup_snapshot")
  end

  it "returns the promoted client and pay-period lineage after a successful apply" do
    periods = [
      create(:pay_period, company: target_company, status: "committed"),
      create(:pay_period, company: target_company, status: "committed")
    ]
    promotion = instance_double(MigrationPromotion::Apply, call: periods)
    expect(MigrationPromotion::Apply).to receive(:new).with(
      rehearsal: rehearsal,
      actor: admin,
      acknowledgement: MigrationPromotion::Apply::ACKNOWLEDGEMENT
    ).and_return(promotion)

    post "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion", params: {
      acknowledgement: MigrationPromotion::Apply::ACKNOWLEDGEMENT
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "company" => include("id" => target_company.id),
      "promoted_pay_period_ids" => periods.map(&:id)
    )
  end

  it "returns validation details when apply revalidation blocks the handoff" do
    promotion = instance_double(MigrationPromotion::Apply)
    allow(promotion).to receive(:call).and_raise(ArgumentError, "The clean client changed after the backup")
    allow(MigrationPromotion::Apply).to receive(:new).and_return(promotion)

    post "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion", params: {
      acknowledgement: MigrationPromotion::Apply::ACKNOWLEDGEMENT
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to eq([ "The clean client changed after the backup" ])
  end

  %w[accountant manager].each do |role|
    it "does not allow a #{role} to preview or apply a live-client promotion" do
      staff_user = create(:user, company: target_company, organization: organization, role: role)
      create(:company_assignment, user: staff_user, company: target_company)
      create(:company_assignment, user: staff_user, company: rehearsal, workspace_access_level: "reviewer")
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(staff_user)
      allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user_id).and_return(staff_user.id)

      get "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion_preview"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Admin access required")

      post "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion_backup", params: {
        acknowledgement: MigrationPromotion::CreateBackup::ACKNOWLEDGEMENT
      }
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/admin/companies/#{rehearsal.id}/migration_promotion", params: {
        acknowledgement: MigrationPromotion::Apply::ACKNOWLEDGEMENT
      }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
