# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261113090000_add_portal_message_attachments_and_file_requests")

RSpec.describe "Portal message attachments", type: :request do
  let(:org) { create(:organization) }
  let(:company) { create(:company, organization: org) }
  let(:other_company) { create(:company, organization: org) }
  let(:client) { create(:user, company: company, organization: org, role: "client", created_at: 1.year.ago) }
  let(:staff) { create(:user, company: company, organization: org, role: "accountant", created_at: 1.year.ago) }
  let(:thread) { create(:client_portal_thread, company: company, created_by: client) }

  before do
    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
    create(:company_assignment, user: staff, company: company)
    PortalNotificationRecipient.create!(company: company, user: staff)
  end

  def as_client
    [ Api::V1::Client::PortalMessagesController, Api::V1::Client::PortalThreadsController, Api::V1::Client::DocumentsController ].each do |controller|
      stub_portal_user(controller, client, company)
    end
  end

  def as_staff
    [ Api::V1::Admin::PortalMessagesController, Api::V1::Admin::PortalThreadsController, Api::V1::Admin::ClientDocumentsController ].each do |controller|
      stub_portal_user(controller, staff, company)
    end
  end

  def document(**attrs)
    create(:client_document, { company: company, uploaded_by: client }.merge(attrs))
  end

  def send_message(target = thread, **params)
    post "/api/v1/#{params.delete(:namespace) || 'client'}/portal_threads/#{target.id}/messages", params: params
  end

  describe "several files on one message" do
    before { as_client }

    it "saves them in order, keeps the first in the legacy field and names every file in activity" do
      first = document(title: "Timesheet week 1")
      second = document(title: "Timesheet week 2")
      send_message(body: "Both weeks", document_ids: [ second.id, first.id ], idempotency_key: "two-files")

      expect(response).to have_http_status(:created)
      data = response.parsed_body.fetch("data")
      expect(data.fetch("documents").map { |row| row["id"] }).to eq([ second.id, first.id ])
      expect(data.dig("document", "id")).to eq(second.id)
      message = ClientPortalMessage.find(data.fetch("id"))
      expect(message.client_document_id).to eq(second.id)
      expect(message.attachments.pluck(:client_document_id, :position)).to eq([ [ second.id, 0 ], [ first.id, 1 ] ])
      log = AuditLog.find_by!(action: "client_portal_messages#create", record_id: message.id)
      expect(log.metadata).to include("attachment_ids" => [ second.id, first.id ], "attachment_titles" => [ "Timesheet week 2", "Timesheet week 1" ])
      event = PortalNotificationEvent.find_by!(event_type: "client_message")
      expect(event.metadata).to include("attachment_count" => 2)
    end

    it "sends files without text, and refuses more than ten" do
      send_message(document_ids: [ document.id ], idempotency_key: "file-only")
      expect(response).to have_http_status(:created)

      documents = Array.new(11) { document }
      expect { send_message(body: "Too many", document_ids: documents.map(&:id)) }.not_to change(ClientPortalMessage, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "client_document").join).to include("no more than 10")
    end

    it "still accepts the single document_id field" do
      file = document
      send_message(body: "Old client", document_id: file.id)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "documents", 0, "id")).to eq(file.id)
    end

    it "starts a conversation with several files" do
      files = [ document, document ]
      post "/api/v1/client/portal_threads", params: { subject: "Hours", body: "See attached", document_ids: files.map(&:id), idempotency_key: "new-thread" }
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "messages", 0, "documents").map { |row| row["id"] }).to eq(files.map(&:id))

      post "/api/v1/client/portal_threads", params: { subject: "Hours", body: "See attached", document_ids: files.reverse.map(&:id), idempotency_key: "new-thread" }
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "files that cannot be attached" do
    it "treats another company's file as not found and saves nothing" do
      as_client
      foreign = create(:client_document, company: other_company, uploaded_by: client)
      expect { send_message(body: "Wrong client", document_ids: [ document.id, foreign.id ]) }.not_to change(ClientPortalMessage, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "client_document")).to eq([ "not found" ])
      expect(PortalMessageAttachment.count).to eq(0)
    end

    it "hides staff-only files from clients and refuses them from staff without sharing them" do
      private_file = document(uploaded_by: staff, visible_to_client: false, shared_by_staff: true)
      as_client
      send_message(body: "Guessing ids", document_ids: [ private_file.id ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "client_document")).to eq([ "not found" ])

      as_staff
      send_message(namespace: "admin", body: "Internal file", document_ids: [ private_file.id ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("details", "client_document")).to eq([ "must be visible to the client" ])
      expect(private_file.reload.visible_to_client).to be(false)
      expect(ClientPortalMessage.count).to eq(0)
    end

    it "refuses an archived file but keeps it as a named record on older messages" do
      as_client
      file = document(title: "Old notice")
      send_message(body: "Here it is", document_ids: [ file.id ])
      file.archive_or_destroy!(actor: staff)
      expect(file.reload).to be_archived

      send_message(body: "Again", document_ids: [ file.id ])
      expect(response).to have_http_status(:unprocessable_entity)

      get "/api/v1/client/portal_threads/#{thread.id}"
      attached = response.parsed_body.dig("data", "messages", 0, "documents", 0)
      expect(attached).to include("id" => file.id, "title" => "Old notice")
      expect(attached.fetch("archived_at")).to be_present
      expect(attached.fetch("preview_available")).to be(false)
    end

    it "lists only attachable files in the server picker search, beyond the first page" do
      as_client
      wanted = document(title: "Riley timesheet November", created_at: 2.years.ago)
      30.times { |index| document(title: "Recent file #{index}") }
      document(title: "Riley timesheet archived").update!(archived_at: Time.current, archived_by: staff)
      document(title: "Riley timesheet scanning", scan_status: "pending")
      create(:client_document, company: other_company, uploaded_by: client, title: "Riley timesheet other client")

      get "/api/v1/client/documents", params: { search: "riley timesheet", attachable: true, per_page: 25 }
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).to eq([ wanted.id ])

      as_staff
      document(title: "Riley timesheet staff only", visible_to_client: false, uploaded_by: staff)
      get "/api/v1/admin/client_documents", params: { search: "riley timesheet", attachable: true }
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).to eq([ wanted.id ])
    end
  end

  describe "upload, then send" do
    before { as_client }

    def upload(key, name = "hours.pdf", marker: "a")
      post "/api/v1/client/documents", params: { files: [ synthetic_pdf(name, marker: marker) ], category: "payroll_source", for_message: true, upload_key: key }
    end

    it "does not duplicate files or the message when the send fails and the person retries" do
      upload("upload-1")
      expect(response).to have_http_status(:created)
      uploaded_id = response.parsed_body.dig("data", 0, "id")
      # The composer's alert comes with the message, not with the upload.
      expect(PortalNotificationEvent.where(event_type: "client_upload")).to be_empty

      # The response was lost, so the browser uploads the same file again.
      expect { upload("upload-1") }.not_to change(ClientDocument, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", 0, "id")).to eq(uploaded_id)
      expect(AuditLog.where(action: "client_documents#create").count).to eq(1)

      # The send fails after the message would have been saved.
      calls = 0
      allow(PortalNotifications).to receive(:message_created!).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::StatementInvalid, "connection lost" if calls == 1

        original.call(*args)
      end
      expect { send_message(body: "Hours attached", document_ids: [ uploaded_id ], idempotency_key: "send-1") }.to raise_error(ActiveRecord::StatementInvalid)
      expect(ClientPortalMessage.count).to eq(0)
      expect(PortalMessageAttachment.count).to eq(0)

      send_message(body: "Hours attached", document_ids: [ uploaded_id ], idempotency_key: "send-1")
      expect(response).to have_http_status(:created)
      send_message(body: "Hours attached", document_ids: [ uploaded_id ], idempotency_key: "send-1")
      expect(response).to have_http_status(:ok)
      expect(ClientPortalMessage.count).to eq(1)
      expect(ClientDocument.where(company_id: company.id).count).to eq(1)
      expect(PortalNotificationEvent.where(event_type: "client_message").count).to eq(1)
    end

    it "refuses to report a replay when a file from that upload has since been deleted" do
      files = -> { [ synthetic_pdf("week-1.pdf", marker: "w1"), synthetic_pdf("week-2.pdf", marker: "w2") ] }
      post "/api/v1/client/documents", params: { files: files.call, category: "payroll_source", for_message: true, upload_key: "two-files" }
      expect(response).to have_http_status(:created)
      second_id = response.parsed_body.dig("data", 1, "id")
      delete "/api/v1/client/documents/#{second_id}"
      expect(response).to have_http_status(:no_content)

      expect do
        post "/api/v1/client/documents", params: { files: files.call, category: "payroll_source", for_message: true, upload_key: "two-files" }
      end.not_to change(ClientDocument, :count)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.fetch("error")).to include("Some files from this upload were removed")
    end

    it "refuses a retry key reused for different files" do
      upload("upload-2", marker: "first")
      upload("upload-2", marker: "second")
      expect(response).to have_http_status(:conflict)
      expect(ClientDocument.count).to eq(1)
    end
  end

  describe "the Client Inbox document queue" do
    it "keeps an unreviewed library upload after it is attached, and leaves composer uploads to the message" do
      as_client
      post "/api/v1/client/documents", params: { files: [ synthetic_pdf("notice.pdf", marker: "lib") ], category: "tax_notice" }
      library_id = response.parsed_body.dig("data", 0, "id")
      post "/api/v1/client/documents", params: { files: [ synthetic_pdf("hours.pdf", marker: "msg") ], category: "payroll_source", for_message: true, upload_key: "composer" }
      composer_id = response.parsed_body.dig("data", 0, "id")
      send_message(body: "Both files", document_ids: [ library_id, composer_id ])
      expect(response).to have_http_status(:created)
      expect(ClientDocument.find(composer_id).uploaded_for_message).to be(true)
      expect(ClientDocument.find(library_id).uploaded_for_message).to be(false)

      allow_any_instance_of(Api::V1::Admin::ClientInboxController).to receive(:current_user) { User.find(staff.id) }
      get "/api/v1/admin/client_inbox", params: { status: "waiting", kind: "document" }
      expect(response.parsed_body.fetch("data").map { |row| row["id"] }).to eq([ library_id ])
    end
  end

  describe "a message saved before the join table" do
    it "replays its retry key with the legacy file and keeps that file fixed" do
      as_client
      file = document
      legacy = ClientPortalMessage.create!(client_portal_thread: thread, company: company, author: client, body: "Legacy", attach_documents: [ file ], idempotency_key: "legacy-key")
      PortalMessageAttachment.where(client_portal_message_id: legacy.id).delete_all

      send_message(body: "Legacy", document_ids: [ file.id ], idempotency_key: "legacy-key")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "id")).to eq(legacy.id)
      expect(ClientPortalMessage.find(legacy.id).attachment_ids).to eq([ file.id ])

      other = document
      begin
        ClientPortalMessage.find(legacy.id).update!(client_document_id: other.id)
      rescue ActiveRecord::ActiveRecordError
        # Rejected outright, depending on the readonly-attribute setting.
      end
      expect(legacy.reload.client_document_id).to eq(file.id)
    end
  end

  describe "a reply to a resolved conversation" do
    it "reopens it in the same transaction and records why" do
      thread.update!(status: "resolved", resolved_at: 1.hour.ago, resolved_by: staff)
      as_client
      send_message(body: "One more question")
      expect(thread.reload.status).to eq("open")
      expect(thread.resolved_at).to be_nil
      log = AuditLog.find_by!(action: "client_portal_threads#reopened", record_id: thread.id)
      expect(log.metadata).to include("reason" => "reply")
      expect(log.user_id).to eq(client.id)
    end
  end

  describe "existing single attachments" do
    let(:migration) { AddPortalMessageAttachmentsAndFileRequests.new }

    it "are copied into the join table and serialize the same way" do
      file = document(title: "Legacy notice")
      migration.suppress_messages { migration.down }
      ClientPortalMessage.reset_column_information
      legacy_id = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        INSERT INTO client_portal_messages (client_portal_thread_id, company_id, author_id, body, client_document_id, author_audience, created_at, updated_at)
        VALUES (#{thread.id}, #{company.id}, #{client.id}, 'Legacy', #{file.id}, 'client', NOW(), NOW()) RETURNING id
      SQL
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        INSERT INTO client_portal_messages (client_portal_thread_id, company_id, author_id, body, author_audience, created_at, updated_at)
        VALUES (#{thread.id}, #{company.id}, #{client.id}, 'No file', 'client', NOW(), NOW())
      SQL
      migration.suppress_messages { migration.up }
      [ ClientPortalMessage, ClientDocument, PortalMessageAttachment, PortalFileRequest ].each(&:reset_column_information)

      expect(PortalMessageAttachment.pluck(:client_portal_message_id, :client_document_id, :position)).to eq([ [ legacy_id, file.id, 0 ] ])
      message = ClientPortalMessage.find(legacy_id)
      expect(message.kind).to eq("message")
      payload = ClientPortalThreadSerializer.new(current_user: client).message(message)
      expect(payload.dig(:document, :id)).to eq(file.id)
      expect(payload[:documents].map { |row| row[:id] }).to eq([ file.id ])
      expect(file.reload.retained_evidence?).to be(true)
    end
  end
end
