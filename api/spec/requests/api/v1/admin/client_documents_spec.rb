# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::ClientDocuments", type: :request do
  let!(:company) { create(:company, name: "Admin Docs Co") }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "admin-docs@example.com") }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/client_portal_upload.txt") }
  let(:upload) { Rack::Test::UploadedFile.new(fixture_path, "text/plain") }
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

    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
    storage = R2StorageService.new
    storage.upload(document.file_key, "admin review document", content_type: "text/plain")
    storage.upload(document.preview_file_key, "%PDF-1.4\npreview", content_type: "application/pdf")
  end

  it "allows staff to upload a document for client portal sharing" do
    expect do
      post "/api/v1/admin/client_documents",
        params: {
          title: "Payroll packet",
          category: "payroll_source",
          notes: "Shared by accounting",
          visible_to_client: "true",
          file: upload
        }
    end.to change(ClientDocument, :count).by(1)

    expect(response).to have_http_status(:created)
    created = ClientDocument.order(:created_at).last
    expect(created.shared_by_staff).to be(true)
    expect(created.visible_to_client).to be(true)
    expect(created.uploaded_by).to eq(admin_user)
    expect(AuditLog.where(action: "admin_client_documents#create", record_id: created.id)).to exist
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

  it "retains a document and both storage objects while it is actively linked to readiness" do
    employee = create(:employee, company: company)
    document.update!(employee: employee)
    requirement = create(
      :employee_document_requirement,
      company: company,
      employee: employee,
      client_document: document,
      status: "received",
      received_at: Time.current
    )

    expect do
      delete "/api/v1/admin/client_documents/#{document.id}"
    end.not_to change(ClientDocument, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("linked")
    expect(requirement.reload.client_document).to eq(document)
    expect_readiness_storage_to_exist(document)
  end

  it "retains a document and both storage objects when only readiness history links it" do
    employee = create(:employee, company: company)
    document.update!(employee: employee)
    requirement = create(:employee_document_requirement, company: company, employee: employee)
    event = requirement.events.create!(
      company: company,
      employee: employee,
      client_document: document,
      document_title: document.title,
      actor: admin_user,
      event_type: "document_received",
      from_status: "missing",
      to_status: "received"
    )

    expect do
      delete "/api/v1/admin/client_documents/#{document.id}"
    end.not_to change(ClientDocument, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("linked")
    expect(event.reload.client_document).to eq(document)
    expect_readiness_storage_to_exist(document)
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


  def expect_readiness_storage_to_exist(retained_document)
    storage = R2StorageService.new
    expect(storage.download(retained_document.file_key)).to be_present
    expect(storage.download(retained_document.preview_file_key)).to be_present
  end
end
