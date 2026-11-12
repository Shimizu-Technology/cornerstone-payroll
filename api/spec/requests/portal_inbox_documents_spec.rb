# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Inbox document receipts and search", type: :request do
  let(:org) { create(:organization) }
  let(:company) { create(:company, organization: org) }
  let(:staff) { create(:user, company: company, organization: org, role: :manager, platform_owner: false, created_at: 1.year.ago) }
  let(:document) { create(:client_document, company: company) }

  before do
    actor = staff
    [ Api::V1::Admin::ClientDocumentsController, Api::V1::Admin::ClientInboxController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user) { User.find(actor.id) }
    end
  end

  it "keeps personal read state separate from an explicit attributable staff review" do
    document
    post "/api/v1/admin/client_documents/#{document.id}/opened"
    expect(response).to have_http_status(:no_content)
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body["data"]).to include("unread_count" => 0, "waiting_count" => 1)
    expect(document.reload.reviewed_at).to be_nil
    post "/api/v1/admin/client_documents/#{document.id}/review"
    expect(response).to have_http_status(:ok), response.body
    expect(document.reload.reviewed_by).to eq(staff)
    expect(AuditLog.where(action: "portal_documents#reviewed", record_id: document.id).count).to eq(1)
    post "/api/v1/admin/client_documents/#{document.id}/review"
    expect(AuditLog.where(action: "portal_documents#reviewed", record_id: document.id).count).to eq(1)
    get "/api/v1/admin/client_inbox/counts"
    expect(response.parsed_body["data"]).to include("waiting_count" => 0)
  end

  it "keeps unsafe or archived documents from being marked reviewed" do
    document.update!(scan_status: "pending")
    post "/api/v1/admin/client_documents/#{document.id}/review"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(document.reload.reviewed_at).to be_nil
    document.update!(scan_status: "clean", archived_at: Time.current)
    post "/api/v1/admin/client_documents/#{document.id}/review"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(document.reload.reviewed_at).to be_nil
  end

  it "returns a deliberate retention error when deleting a document reviewer" do
    admin = create(:user, organization: org, company: company, role: :org_admin, platform_owner: false)
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(admin)
    document.update!(reviewed_by: staff, reviewed_at: Time.current)
    delete "/api/v1/admin/users/#{staff.id}"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Deactivate", "review history")
    expect(User.exists?(staff.id)).to be(true)
    expect(document.reload.reviewed_by_id).to eq(staff.id)
  end

  it "bounds document search, finds an older file and supports authorized exact lookup" do
    old = create(:client_document, company: company, title: "Prior year notice", created_at: 1.year.ago)
    3.times { create(:client_document, company: company) }
    get "/api/v1/admin/client_documents", params: { per_page: 2 }
    expect(response.parsed_body["data"].map { |r| r["id"] }).not_to include(old.id)
    get "/api/v1/admin/client_documents", params: { search: "Prior year", per_page: 2 }
    expect(response.parsed_body["data"].map { |r| r["id"] }).to eq([ old.id ])
    expect(response.parsed_body.dig("meta", "per_page")).to eq(2)
    get "/api/v1/admin/client_documents/#{old.id}"
    expect(response).to have_http_status(:ok)
    other = create(:client_document)
    get "/api/v1/admin/client_documents/#{other.id}"
    expect(response).to have_http_status(:not_found)
    post "/api/v1/admin/client_documents/#{other.id}/review"
    expect(response).to have_http_status(:not_found)
  end
end
