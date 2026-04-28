# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::ClientDocuments", type: :request do
  let!(:company) { create(:company, name: "Admin Docs Co") }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "admin-docs@example.com") }
  let!(:document) do
    create(:client_document,
      company: company,
      uploaded_by: admin_user,
      title: "Admin Review Doc",
      file_name: "admin-review.txt",
      file_key: "client_documents/company_#{company.id}/2026/04/admin-review.txt",
      preview_file_key: "client_documents/company_#{company.id}/previews/admin-review-preview.pdf",
      preview_status: "ready",
      preview_content_type: "application/pdf",
      preview_generated_at: Time.current)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_company_id).and_return(company.id)

    FileUtils.rm_rf(Rails.root.join("tmp/local_r2_storage"))
    storage = R2StorageService.new
    storage.upload(document.file_key, "admin review document", content_type: "text/plain")
    storage.upload(document.preview_file_key, "%PDF-1.4\npreview", content_type: "application/pdf")
  end

  it "keeps storage intact if the database destroy fails" do
    storage = R2StorageService.new
    expect(storage.download(document.file_key)).to be_present
    expect(storage.download(document.preview_file_key)).to be_present

    allow_any_instance_of(ClientDocument).to receive(:destroy!)
      .and_raise(ActiveRecord::RecordNotDestroyed.new("fail destroy", document))

    expect do
      delete "/api/v1/admin/client_documents/#{document.id}"
    end.to raise_error(ActiveRecord::RecordNotDestroyed)

    expect(ClientDocument.exists?(document.id)).to be(true)
    expect(storage.download(document.file_key)).to be_present
    expect(storage.download(document.preview_file_key)).to be_present
  end

  it "writes an audit log only after a successful delete" do
    destroy_audit_count = AuditLog.where(action: "admin_client_documents#destroy", record_id: document.id).count

    expect do
      delete "/api/v1/admin/client_documents/#{document.id}"
    end.to change(ClientDocument, :count).by(-1)

    expect(response).to have_http_status(:no_content)
    expect(
      AuditLog.where(action: "admin_client_documents#destroy", record_id: document.id).count
    ).to eq(destroy_audit_count + 1)
  end

  it "does not write a destroy audit log if the database delete fails" do
    destroy_audit_count = AuditLog.where(action: "admin_client_documents#destroy", record_id: document.id).count

    allow_any_instance_of(ClientDocument).to receive(:destroy!)
      .and_raise(ActiveRecord::RecordNotDestroyed.new("fail destroy", document))

    expect do
      delete "/api/v1/admin/client_documents/#{document.id}"
    end.to raise_error(ActiveRecord::RecordNotDestroyed)

    expect(
      AuditLog.where(action: "admin_client_documents#destroy", record_id: document.id).count
    ).to eq(destroy_audit_count)
  end
end
