# frozen_string_literal: true

require "rails_helper"
require "support/aire_history_approval_evidence"

RSpec.describe "AIRE one-summary history approval", type: :request do
  include_context "aire history approval evidence"

  before do
    allow_any_instance_of(Api::V1::Admin::AireHistoryApprovalsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::AireHistoryApprovalsController).to receive(:current_company_id).and_return(company.id)
  end

  def endpoint(action)
    "/api/v1/admin/time_tracking_sources/#{source.id}/history_approval/#{action}"
  end

  it "returns one unapproved summary and applies strict history with one attestation" do
    post endpoint("preview"), as: :json
    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page).to include("history_coverage_verified" => true, "approved_at" => nil)
    post endpoint("approve"), params: page.slice("review_id", "digest", "attestation"), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["approved_at"]).to be_present
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(AireVerifiedHistoryRolloutReceipt.sole.coverage_verified).to be(true)
    expect(CheckEvent.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
    expect(AirePayrollCalendarPublication.count).to eq(0)
  end

  it "reports stale entry IDs with 409 and no receipt" do
    post endpoint("preview"), as: :json
    page = response.parsed_body
    row["version"] += 1
    post endpoint("approve"), params: page.slice("review_id", "digest", "attestation"), as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["changes"]).to include(a_string_matching(/41/))
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "never trusts a client packet or forged coverage flag" do
    post endpoint("preview"), as: :json
    page = response.parsed_body
    row["history_evidence"]["baseline_lines"].sole["current_content_matches"] = false
    post endpoint("approve"), params: page.slice("review_id", "digest", "attestation").merge(
      history_coverage_verified: true, reviewed_dispositions: [], delivered_checks: [ { payroll_item_id: item.id } ]), as: :json
    expect(response).to have_http_status(:conflict)
    expect(CheckEvent.count).to eq(0)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "requires the attestation" do
    post endpoint("preview"), as: :json
    post endpoint("approve"), params: response.parsed_body.slice("review_id", "digest"), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "denies a manager before querying AIRE or saving a draft" do
    actor.update!(role: "manager")
    expect(client).not_to receive(:payroll_cockpit_history_entries)
    post endpoint("preview"), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(AireHistoryReview.count).to eq(0)
  end

  it "does not cross client/source boundaries" do
    other = create(:time_tracking_source, company: create(:company))
    post "/api/v1/admin/time_tracking_sources/#{other.id}/history_approval/preview", as: :json
    expect(response).to have_http_status(:not_found)
    expect(AireHistoryReview.count).to eq(0)
  end

  it "does not use another reviewer's draft" do
    page = history_service.prepare!
    AireHistoryReview.find(page["review_id"]).update!(actor: create(:user, company: company, role: "admin"))
    post endpoint("approve"), params: page.slice("review_id", "digest", "attestation"), as: :json
    expect(response).to have_http_status(:not_found)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "stays inert while connected payroll is paused" do
    allow(ConnectedPayrollMode).to receive(:enabled?).and_return(false)
    expect(client).not_to receive(:payroll_cockpit_history_entries)
    post endpoint("preview"), as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(AireHistoryReview.count).to eq(0)
  end

  context "as an accountant" do
    let(:actor) { create(:user, company: company, organization: company.organization, role: "accountant") }
    before { CompanyAssignment.find_or_create_by!(user: actor, company: company) }

    it "approves assigned client history without client-management privileges" do
      post endpoint("preview"), as: :json
      expect(response).to have_http_status(:ok)
      page = response.parsed_body
      post endpoint("approve"), params: page.slice("review_id", "digest", "attestation"), as: :json
      expect(response).to have_http_status(:ok)
      expect(AireVerifiedHistoryRolloutReceipt.sole.approved_by).to eq(actor)
    end

    it "rejects an expired assignment even when the client is still the home company" do
      page = history_service.prepare!
      actor.company_assignments.find_by!(company: company).update!(expires_at: 1.minute.ago)
      post endpoint("approve"), params: page.slice("review_id", "digest", "attestation"), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    end
  end
end
