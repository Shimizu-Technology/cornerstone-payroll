# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::Documents", type: :request do
  let!(:company) { create(:company, name: "Docs Co") }
  let!(:department) { create(:department, company: company) }
  let!(:client_user) { create(:user, company: company, role: "client", email: "docs-client@example.com") }
  let!(:other_client_user) { create(:user, company: company, role: "client", email: "other-docs-client@example.com") }
  let!(:employee) { create(:employee, company: company, department: department, first_name: "Ava", last_name: "Cruz") }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/client_portal_upload.txt") }
  let(:upload) { Rack::Test::UploadedFile.new(fixture_path, "text/plain") }

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    CompanyAssignment.create!(user: other_client_user, company: company)
    allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_user_id).and_return(client_user.id)
    allow_any_instance_of(Api::V1::Client::DocumentsController).to receive(:current_company_id).and_return(company.id)
    FileUtils.rm_rf(Rails.root.join("tmp/local_r2_storage"))
  end

  describe "document upload lifecycle" do
    it "creates, lists, downloads, and deletes a client document" do
      expect do
        post "/api/v1/client/documents",
          params: {
            title: "I-9 Packet",
            category: "employee_onboarding",
            employee_id: employee.id,
            notes: "Signed onboarding docs",
            file: upload
          }
      end.to change(ClientDocument, :count).by(1)

      expect(response).to have_http_status(:created)
      created_id = response.parsed_body.fetch("data").first.fetch("id")
      document = ClientDocument.find(created_id)
      expect(document.download_filename).to eq("client_portal_upload.txt")

      get "/api/v1/client/documents"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("data")).to include(
        include(
          "id" => created_id,
          "employee_id" => employee.id,
          "uploaded_by_id" => client_user.id,
          "category" => "employee_onboarding"
        )
      )

      get "/api/v1/client/documents/#{created_id}/download"
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("text/plain")
      expect(response.body).to include("Client upload test document")

      expect do
        delete "/api/v1/client/documents/#{created_id}"
      end.to change(ClientDocument, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "does not allow one client user to delete another uploader's document" do
      document = ClientDocument.create!(
        company: company,
        employee: employee,
        uploaded_by: other_client_user,
        title: "Other uploader doc",
        category: "misc",
        file_name: "client_portal_upload.txt",
        file_key: "client_documents/company_#{company.id}/#{SecureRandom.uuid}_client_portal_upload.txt",
        content_type: "text/plain",
        file_size: 32,
        preview_status: "not_required"
      )

      expect do
        delete "/api/v1/client/documents/#{document.id}"
      end.not_to change(ClientDocument, :count)

      expect(response).to have_http_status(:not_found)
      expect(ClientDocument.exists?(document.id)).to be(true)
    end

    it "does not list staff-only documents in the client portal" do
      hidden_document = create(:client_document,
        company: company,
        uploaded_by: client_user,
        title: "Internal memo",
        visible_to_client: false)

      get "/api/v1/client/documents"

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body.fetch("data").map { |document| document.fetch("id") }
      expect(ids).not_to include(hidden_document.id)
    end

    it "keeps storage intact if the database destroy fails" do
      post "/api/v1/client/documents",
        params: {
          title: "I-9 Packet",
          category: "employee_onboarding",
          employee_id: employee.id,
          notes: "Signed onboarding docs",
          file: upload
        }

      expect(response).to have_http_status(:created)
      created_id = response.parsed_body.fetch("data").first.fetch("id")
      document = ClientDocument.find(created_id)
      storage = R2StorageService.new
      expect(storage.download(document.file_key)).to be_present

      allow_any_instance_of(ClientDocument).to receive(:destroy!)
        .and_raise(ActiveRecord::RecordNotDestroyed.new("fail destroy", document))

      expect do
        delete "/api/v1/client/documents/#{created_id}"
      end.to raise_error(ActiveRecord::RecordNotDestroyed)

      expect(ClientDocument.exists?(created_id)).to be(true)
      expect(storage.download(document.file_key)).to be_present
    end

    it "does not write a destroy audit log if the database delete fails" do
      post "/api/v1/client/documents",
        params: {
          title: "I-9 Packet",
          category: "employee_onboarding",
          employee_id: employee.id,
          notes: "Signed onboarding docs",
          file: upload
        }

      expect(response).to have_http_status(:created)
      created_id = response.parsed_body.fetch("data").first.fetch("id")
      document = ClientDocument.find(created_id)
      destroy_audit_count = AuditLog.where(action: "client_documents#destroy", record_id: document.id).count

      allow_any_instance_of(ClientDocument).to receive(:destroy!)
        .and_raise(ActiveRecord::RecordNotDestroyed.new("fail destroy", document))

      expect do
        delete "/api/v1/client/documents/#{created_id}"
      end.to raise_error(ActiveRecord::RecordNotDestroyed)

      expect(
        AuditLog.where(action: "client_documents#destroy", record_id: document.id).count
      ).to eq(destroy_audit_count)
    end

    it "rejects unsupported upload types before storing them" do
      file = Tempfile.new([ "malware", ".exe" ])
      file.binmode
      file.write("pretend binary")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "application/x-msdownload", original_filename: "malware.exe")

      expect do
        post "/api/v1/client/documents",
          params: {
            title: "Bad upload",
            category: "misc",
            file: upload
          }
      end.not_to change(ClientDocument, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("details").fetch("file").join(" ")).to include("must be one of")
    ensure
      file.close!
    end

    it "uploads multiple mixed file types in one request" do
      csv = Tempfile.new([ "client-portal-upload", ".csv" ])
      csv.write("employee,hours\nAva Cruz,40\n")
      csv.rewind
      csv_upload = Rack::Test::UploadedFile.new(csv.path, "text/csv", original_filename: "hours.csv")

      expect do
        post "/api/v1/client/documents",
          params: {
            category: "payroll_source",
            employee_id: employee.id,
            notes: "Weekly source docs",
            files: [ upload, csv_upload ]
          }
      end.to change(ClientDocument, :count).by(2)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("message")).to eq("2 documents uploaded successfully")
      expect(response.parsed_body.fetch("data")).to match_array(
        [
          include("file_name" => "client_portal_upload.txt", "category" => "payroll_source"),
          include("file_name" => "hours.csv", "category" => "payroll_source")
        ]
      )
    ensure
      csv.close!
    end

    it "generates a preview on demand for office-style files that need server rendering" do
      post "/api/v1/client/documents",
        params: {
          title: "Text upload",
          category: "misc",
          file: upload
        }

      expect(response).to have_http_status(:created)
      created_id = response.parsed_body.fetch("data").first.fetch("id")
      document = ClientDocument.find(created_id)
      expect(document.preview_status).to eq("pending")

      allow_any_instance_of(ClientDocumentPreviewGenerator).to receive(:generate!) do
        preview_key = "client_documents/company_#{company.id}/previews/test-preview.pdf"
        R2StorageService.new.upload(preview_key, StringIO.new("%PDF-1.4\npreview"), content_type: "application/pdf")
        document.update!(
          preview_status: "ready",
          preview_file_key: preview_key,
          preview_content_type: "application/pdf",
          preview_generated_at: Time.current,
          preview_error: nil
        )
      end

      get "/api/v1/client/documents/#{created_id}/preview"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("application/pdf")
      expect(response.body).to start_with("%PDF")
    end

    it "hides internal preview generator details from client responses" do
      docx = Tempfile.new([ "client-portal-upload", ".docx" ])
      docx.write("pretend docx payload")
      docx.rewind
      docx_upload = Rack::Test::UploadedFile.new(
        docx.path,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        original_filename: "payroll-notes.docx"
      )

      post "/api/v1/client/documents",
        params: {
          title: "Text upload",
          category: "misc",
          file: docx_upload
        }

      expect(response).to have_http_status(:created)
      created_id = response.parsed_body.fetch("data").first.fetch("id")
      document = ClientDocument.find(created_id)
      document.update!(
        preview_status: "failed",
        preview_error: "LibreOffice is not installed on this server"
      )
      allow_any_instance_of(ClientDocumentPreviewGenerator)
        .to receive(:generate!)
        .and_raise(ClientDocumentPreviewGenerator::GenerationUnavailable, "LibreOffice is not installed on this server")

      get "/api/v1/client/documents"
      listed_document = response.parsed_body.fetch("data").find { |item| item["id"] == created_id }
      expect(listed_document.fetch("preview_error")).to eq("Preview is unavailable for this file.")

      get "/api/v1/client/documents/#{created_id}/preview"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Preview is unavailable for this file.")
    ensure
      docx.close!
    end
  end
end
