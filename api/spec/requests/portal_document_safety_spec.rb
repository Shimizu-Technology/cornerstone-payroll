# frozen_string_literal: true

require "rails_helper"

RSpec.shared_examples "safe portal documents" do |namespace, controller, role|
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, role: role) }
  let(:base) { "/api/v1/#{namespace}" }

  before do
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
  end

  it "rejects spoofed MIME, macros, malformed containers and empty files before storage" do
    files = [ portal_upload("renamed.pdf", "MZ\x00synthetic", "application/pdf"),
      portal_upload("macro.xlsm", office_zip), portal_upload("macro.xlsx", office_zip(extra: { "xl/vbaProject.bin" => "synthetic" })),
      portal_upload("empty.txt", ""), portal_upload("fake.docx", "%PDF-1.4\n") ]
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    expect(storage).not_to receive(:upload)
    files.each do |file|
      expect { post base, params: { file: file } }.not_to change(ClientDocument, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).not_to eq("Validation failed")
    end
  end

  it "rejects oversized files, excessive batches and aggregate bytes" do
    stub_const("ClientDocument::MAX_FILE_SIZE", 10)
    expect { post base, params: { file: portal_upload("large.txt", "x" * 11) } }.not_to change(ClientDocument, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("details", "file").join).to include("25 MB")
    files = Array.new(11) { portal_upload("notes.txt", "notes") }
    post base, params: { files: files }
    expect(response.parsed_body.fetch("error")).to include("10 files")
    stub_const("ClientDocumentUploadService::MAX_TOTAL_BYTES", 8)
    post base, params: { files: files.first(2) }
    expect(response.parsed_body.fetch("error")).to include("50 MB")
  end

  it "rejects ZIP expansion and entry limits" do
    stub_const("ClientDocumentFileValidator::MAX_ZIP_ENTRIES", 3)
    post base, params: { file: portal_upload("many.xlsx", office_zip(extra: { "extra" => "x" })) }
    expect(response.parsed_body.dig("details", "file").join).to include("too many items")
    stub_const("ClientDocumentFileValidator::MAX_ZIP_ENTRIES", 1_000)
    stub_const("ClientDocumentFileValidator::MAX_EXPANDED_BYTES", 2_048)
    post base, params: { file: portal_upload("expands.xlsx", office_zip(extra: { "xl/data.xml" => "x" * 4_096 })) }
    expect(response.parsed_body.dig("details", "file").join).to include("expands")
  end

  it "stores supported content with server MIME and never labels it clean" do
    post base, params: { files: [ portal_upload("notice.pdf", "%PDF-1.4\n"), portal_upload("hours.xlsx", office_zip), portal_upload("hours.csv", "name,hours\nAva,40\n") ] }
    expect(response).to have_http_status(:created), response.body
    documents = response.parsed_body.fetch("data")
    expect(documents.map { |doc| doc.fetch("scan_status") }).to eq(%w[not_scanned not_scanned not_scanned])
    expect(documents.map { |doc| doc.fetch("content_type") }).to eq([ "application/pdf", ClientDocumentFileValidator::TYPES["xlsx"], "text/csv" ])
  end

  it "permits the 45 requests needed to isolate invalid files in a 30-file selection" do
    allow(Rack::Attack.cache).to receive(:count).with("portal-document-uploads/user/#{actor.id}", 60).and_return(45)
    post base, params: { file: portal_upload("notes.txt", "notes") }
    expect(response).to have_http_status(:created)
  end

  it "rate limits the authenticated user with Rack::Attack's counter" do
    allow(Rack::Attack.cache).to receive(:count).with("portal-document-uploads/user/#{actor.id}", 60).and_return(61)
    post base, params: { file: portal_upload("notes.txt", "notes") }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(response.parsed_body.fetch("error")).to include("wait a minute")
  end

  it "keeps cross-company document and employee IDs outside all paths" do
    other = create(:company)
    doc = create(:client_document, company: other, uploaded_by: actor)
    %w[download preview].each do |action|
      get "#{base}/#{doc.id}/#{action}"
      expect(response).to have_http_status(:not_found)
    end
    delete "#{base}/#{doc.id}"
    expect(response).to have_http_status(:not_found)
    post base, params: { file: portal_upload("notes.txt", "notes"), employee_id: create(:employee, company: other).id }
    expect(response).to have_http_status(:not_found)
  end

  it "sets private, nosniff responses and safe filenames for downloads and previews" do
    doc = create(:client_document, company: company, uploaded_by: actor, file_name: "../../bad\r\n.pdf", content_type: "application/pdf")
    R2StorageService.new.upload(doc.file_key, "%PDF-1.4\n", content_type: "application/pdf")
    %w[download preview].each do |action|
      get "#{base}/#{doc.id}/#{action}"
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Content-Disposition"]).not_to match(/\.\.\/|%0D|%0A/)
    end
  end

  it "blocks downloads and previews through an enforcing fake scanner" do
    doc = create(:client_document, company: company, uploaded_by: actor)
    allow(ClientDocumentScanner).to receive(:adapter).and_return(double(allowed?: false))
    %w[download preview].each do |action|
      get "#{base}/#{doc.id}/#{action}"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("safety check")
    end
  end

  it "archives message attachments, retains bytes and serializes a named tombstone" do
    doc = create(:client_document, company: company, uploaded_by: actor)
    R2StorageService.new.upload(doc.file_key, "retained", content_type: "text/plain")
    thread = create(:client_portal_thread, company: company)
    msg = create(:client_portal_message, company: company, client_portal_thread: thread, client_document: doc)
    delete "#{base}/#{doc.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("message")).to include("archived")
    expect(doc.reload.archived_by).to eq(actor)
    expect(msg.reload.client_document).to eq(doc)
    expect(R2StorageService.new.download(doc.file_key)).to eq("retained")
    expect(ClientPortalThreadSerializer.new(current_user: actor).message(msg)[:document]).to include(title: doc.title, archived_at: doc.archived_at)
    delete "#{base}/#{doc.id}"
    expect(response).to have_http_status(:ok)
    expect(doc.reload).to be_archived
  end
end

RSpec.describe "Client document safety", type: :request do
  include_examples "safe portal documents", "client/documents", Api::V1::Client::DocumentsController, "client"
end

RSpec.describe "Staff document safety", type: :request do
  include_examples "safe portal documents", "admin/client_documents", Api::V1::Admin::ClientDocumentsController, "admin"
end

RSpec.describe "Archived evidence access", type: :request do
  let!(:company) { create(:company) }
  let!(:staff) { create(:user, company: company, role: "admin") }
  let!(:client) { create(:user, company: company, role: "client") }
  let!(:document) { create(:client_document, company: company, uploaded_by: client, archived_at: Time.current, archived_by: client, file_name: "w4.pdf", content_type: "application/pdf") }

  before do
    [ [ Api::V1::Admin::ClientDocumentsController, staff ], [ Api::V1::Client::DocumentsController, client ] ].each do |controller, actor|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
    R2StorageService.new.upload(document.file_key, "%PDF-1.4\n", content_type: "application/pdf")
  end

  it "lets staff download and preview archived files while clients remain blocked" do
    %w[download preview].each do |action|
      get "/api/v1/admin/client_documents/#{document.id}/#{action}"
      expect(response).to have_http_status(:ok), response.body
      get "/api/v1/client/documents/#{document.id}/#{action}"
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect { document.ensure_usable_for!(:message_attachment) }.to raise_error(ClientDocumentScanner::Blocked)
    expect { document.ensure_usable_for!(:intake) }.to raise_error(ClientDocumentScanner::Blocked)
  end

  it "lets only staff unarchive evidence and audits the original archive actor/time" do
    original_time = document.archived_at
    post "/api/v1/admin/client_documents/#{document.id}/unarchive"
    expect(response).to have_http_status(:ok), response.body
    expect(document.reload).to have_attributes(archived_at: nil, archived_by_id: nil)
    audit = AuditLog.find_by!(action: "admin_client_documents#unarchive", record_id: document.id)
    expect(audit.user_id).to eq(staff.id)
    expect(audit.metadata).to include("archived_by_id" => client.id)
    expect(Time.iso8601(audit.metadata.fetch("archived_at"))).to be_within(1.second).of(original_time)
    expect(R2StorageService.new.download(document.file_key)).to eq("%PDF-1.4\n")
    post "/api/v1/client/documents/#{document.id}/unarchive"
    expect(response).to have_http_status(:not_found)
  end

  it "does not let staff bypass an infected state or cross-company unarchive" do
    document.update!(scan_status: "infected")
    get "/api/v1/admin/client_documents/#{document.id}/download"
    expect(response).to have_http_status(:unprocessable_entity)
    other = create(:client_document, archived_at: Time.current)
    post "/api/v1/admin/client_documents/#{other.id}/unarchive"
    expect(response).to have_http_status(:not_found)
    expect(other.reload).to be_archived
  end
end

RSpec.describe "Staff unarchive role boundary", type: :request do
  it "denies a client using the staff endpoint" do
    client = create(:user, role: "client")
    document = create(:client_document, company: client.company, uploaded_by: client, archived_at: Time.current)
    allow_any_instance_of(Api::V1::Admin::ClientDocumentsController).to receive(:current_user).and_return(client)
    post "/api/v1/admin/client_documents/#{document.id}/unarchive"
    expect(response).to have_http_status(:forbidden)
    expect(document.reload).to be_archived
    expect(AuditLog.where(action: "admin_client_documents#unarchive", record_id: document.id)).not_to exist
  end
end
