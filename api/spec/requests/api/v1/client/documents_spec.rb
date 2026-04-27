# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::Documents", type: :request do
  let!(:company) { create(:company, name: "Docs Co") }
  let!(:department) { create(:department, company: company) }
  let!(:client_user) { create(:user, company: company, role: "client", email: "docs-client@example.com") }
  let!(:employee) { create(:employee, company: company, department: department, first_name: "Ava", last_name: "Cruz") }
  let(:fixture_path) { Rails.root.join("spec/fixtures/files/client_portal_upload.txt") }
  let(:upload) { Rack::Test::UploadedFile.new(fixture_path, "text/plain") }

  before do
    CompanyAssignment.create!(user: client_user, company: company)
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
  end
end
