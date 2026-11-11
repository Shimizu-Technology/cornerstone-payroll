# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal personal reads and activity", type: :request do
  %w[client manager].each do |role|
    context "as #{role}" do
      let(:company) { create(:company) }
      let(:actor) { create(:user, company: company, role: role) }
      let(:peer) { create(:user, company: company, role: role) }
      let(:namespace) { role == "client" ? "client" : "admin" }
      let(:threads_path) { "/api/v1/#{namespace}/portal_threads" }
      let(:documents_path) { "/api/v1/#{namespace}/#{role == 'client' ? 'documents' : 'client_documents'}" }
      let(:thread) { create(:client_portal_thread, company: company, subject: "November payroll questions") }
      let(:document) { create(:client_document, company: company, uploaded_by: actor, title: "MoSa November hours", content_type: "application/pdf", file_name: "hours.pdf", preview_status: "not_required") }
      let(:storage) { instance_double(R2StorageService, download: "%PDF-1.4 synthetic", delete: true, upload: true) }

      before do
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(actor)
        allow_any_instance_of(ApplicationController).to receive(:current_company_id).and_return(company.id)
        allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
        allow(R2StorageService).to receive(:new).and_return(storage)
      end

      def display_payload(thread)
        get "#{threads_path}/#{thread.id}"
        data = response.parsed_body.fetch("data")
        { foreground: true, display_token: data.fetch("display_token"), displayed_message_ids: data.fetch("messages").map { |message| message.fetch("id") } }
      end

      it "does not read on GET, and records/deduplicates only foreground displayed ranges for this person" do
        message = create(:client_portal_message, client_portal_thread: thread, company: company, author: peer)
        payload = display_payload(thread)
        expect(thread.unread_for?(actor)).to be(true)
        expect(PortalThreadReadReceipt.count).to eq(0)
        expect(AuditLog.where(action: "client_portal_threads#opened")).to be_empty
        post "#{threads_path}/#{thread.id}/mark_read", params: payload.merge(foreground: false), as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(PortalThreadReadReceipt.count).to eq(0)
        post "#{threads_path}/#{thread.id}/mark_read", params: payload, as: :json
        expect(response).to have_http_status(:ok)
        expect(thread.unread_for?(actor)).to be(false)
        expect(thread.unread_for?(peer)).to be(true)
        log = AuditLog.find_by!(action: "client_portal_threads#opened")
        expect(log.subject_name).to eq(thread.subject)
        expect(log.metadata.fetch("displayed_message_ids")).to eq([ message.id ])
        post "#{threads_path}/#{thread.id}/mark_read", params: payload, as: :json
        expect(AuditLog.where(action: "client_portal_threads#opened").count).to eq(1)
        expect(AuditLog.where(action: "client_portal_threads#mark_read").count).to eq(1)
      end

      it "rejects unseen or foreign-user cursors and preserves partial-range unread" do
        first = create(:client_portal_message, client_portal_thread: thread, company: company)
        payload = display_payload(thread)
        second = create(:client_portal_message, client_portal_thread: thread, company: company)
        post "#{threads_path}/#{thread.id}/mark_read", params: payload.merge(displayed_message_ids: [ second.id ]), as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        post "#{threads_path}/#{thread.id}/mark_read", params: payload, as: :json
        expect(response).to have_http_status(:ok)
        expect(thread.unread_for?(actor)).to be(true)
        expect(thread.read_cursor_for(actor)).to eq(first.id)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(peer)
        post "#{threads_path}/#{thread.id}/mark_read", params: payload, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rolls a displayed receipt back when its audit fails" do
        create(:client_portal_message, client_portal_thread: thread, company: company)
        payload = display_payload(thread)
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(action: "client_portal_threads#mark_read")).and_raise("audit down")
        expect { post "#{threads_path}/#{thread.id}/mark_read", params: payload, as: :json }.to raise_error("audit down")
        expect(PortalThreadReadReceipt.count).to eq(0)
        expect(AuditLog.where(action: "client_portal_threads#opened")).to be_empty
      end

      it "sends once on retry, rejects key reuse for different contents and names the attachment" do
        payload = { body: "Please check hours", document_id: document.id, idempotency_key: "retry-1" }
        post "#{threads_path}/#{thread.id}/messages", params: payload
        expect(response).to have_http_status(:created)
        id = response.parsed_body.dig("data", "id")
        post "#{threads_path}/#{thread.id}/messages", params: payload
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "id")).to eq(id)
        expect(thread.messages.count).to eq(1)
        expect(AuditLog.where(action: "client_portal_messages#create").count).to eq(1)
        expect(AuditLog.find_by!(action: "client_portal_messages#create").metadata.fetch("attachment_ids")).to eq([ document.id ])
        post "#{threads_path}/#{thread.id}/messages", params: payload.merge(body: "Different message")
        expect(response).to have_http_status(:conflict)
      end

      it "rolls back thread creation and its first attachment when the audit fails" do
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(action: "client_portal_messages#create")).and_raise("audit down")
        expect { post threads_path, params: { subject: "Hours", body: "Attached", document_id: document.id } }.to raise_error("audit down")
        expect(ClientPortalThread.count).to eq(0)
        expect(ClientPortalMessage.count).to eq(0)
        expect(AuditLog.where(action: "client_portal_threads#create")).to be_empty
      end

      it "records the first message attachment and named subject" do
        post threads_path, params: { subject: "Hours", body: "Attached", document_id: document.id }
        expect(response).to have_http_status(:created)
        log = AuditLog.find_by!(action: "client_portal_messages#create")
        expect(log.subject_name).to eq("Hours")
        expect(log.metadata.fetch("attachment_ids")).to eq([ document.id ])
      end

      it "rolls a reply and thread timestamp back when the audit fails" do
        thread
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(action: "client_portal_messages#create")).and_raise("audit down")
        expect { post "#{threads_path}/#{thread.id}/messages", params: { body: "Unsaved", idempotency_key: "retry-fail" } }.to raise_error("audit down")
        expect(thread.messages.count).to eq(0)
        expect(thread.reload.last_message_at).to be_nil
      end

      it "records named detail, preview and download without bytes and deduplicates passive opens" do
        2.times { post "#{documents_path}/#{document.id}/opened" }
        get "#{documents_path}/#{document.id}/preview"
        expect(response).to have_http_status(:ok)
        2.times { get "#{documents_path}/#{document.id}/download"; expect(response).to have_http_status(:ok) }
        expect(AuditLog.where(action: "portal_documents#opened").count).to eq(1)
        expect(AuditLog.where(action: "portal_documents#download").count).to eq(2)
        logs = AuditLog.where(record_type: "client_documents")
        expect(logs.pluck(:subject_name).uniq).to eq([ document.title ])
        expect(logs.map { |log| log.metadata.fetch("document_version") }.uniq).to eq([ document.id ])
        expect(logs.to_json).not_to include("%PDF")
      end

      it "records missing bytes, failed conversions and denied IDs only as minimal failures" do
        allow(storage).to receive(:download).and_return(nil)
        get "#{documents_path}/#{document.id}/download"
        expect(response).to have_http_status(:not_found)
        get "#{documents_path}/#{document.id}/preview"
        expect(response).to have_http_status(:unprocessable_entity)
        other = create(:client_document, title: "Secret other company")
        get "#{documents_path}/#{other.id}/download"
        expect(response).to have_http_status(:not_found)
        post "#{threads_path}/#{thread.id}/messages", params: { document_id: other.id }
        expect(response).to have_http_status(:unprocessable_entity)
        post "#{threads_path}/#{thread.id}/messages", params: { body: "" }
        expect(response).to have_http_status(:unprocessable_entity)
        failures = AuditLog.where(action: "portal_access#failed")
        expect(failures.count).to eq(5)
        failures.each do |log|
          expect(log.subject_name).to be_nil
          expect(log.company_id).to be_nil
          expect(log.metadata.keys).to match_array(%w[status reason operation])
        end
        expect(failures.to_json).not_to include(other.title, document.title)
        expect(AuditLog.where(action: "portal_documents#preview")).to be_empty
      end

      it "makes upload + audit atomic and cleans uploaded storage on rollback" do
        file = fixture_file_upload("client_portal_upload.txt", "text/plain")
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(record_type: "client_documents")).and_raise("audit down")
        expect { post documents_path, params: { file: file, title: "Rollback hours" } }.to raise_error("audit down")
        expect(ClientDocument.count).to eq(0)
        expect(storage).to have_received(:delete).once
      end

      it "retains and retries storage cleanup after an audited upload rolls back" do
        allow(storage).to receive(:delete).and_raise(R2StorageService::UploadError, "temporary outage")
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(record_type: "client_documents")).and_raise("audit down")
        expect { post documents_path, params: { file: fixture_file_upload("client_portal_upload.txt", "text/plain") } }.to raise_error("audit down")
        expect(ClientDocument.count).to eq(0)
        cleanup = PortalUploadCleanup.sole
        expect(cleanup.file_key).to be_present
        PortalUploadCleanupJob.perform_now(cleanup.id)
        expect(cleanup.reload.completed_at).to be_nil
        expect(cleanup.last_error_class).to eq("R2StorageService::UploadError")
        allow(storage).to receive(:delete).and_return(nil)
        PortalUploadCleanupJob.perform_now
        expect(cleanup.reload.completed_at).to be_present
        expect(cleanup.attempts).to eq(2)
      end

      it "names uploaded documents and employee context, and rolls deletion back on audit failure" do
        post documents_path, params: { file: fixture_file_upload("client_portal_upload.txt", "text/plain"), title: "Named hours" }
        expect(response).to have_http_status(:created)
        doc = ClientDocument.find(response.parsed_body.dig("data", 0, "id"))
        expect(AuditLog.find_by!(record_type: "client_documents").subject_name).to eq("Named hours")
        allow(AuditLog).to receive(:record!).and_call_original
        allow(AuditLog).to receive(:record!).with(hash_including(action: "#{role == 'client' ? 'client_documents' : 'admin_client_documents'}#destroy")).and_raise("audit down")
        expect { delete "#{documents_path}/#{doc.id}" }.to raise_error("audit down")
        expect(ClientDocument.exists?(doc.id)).to be(true)
        expect(storage).not_to have_received(:delete)
      end

      it "records successful deletion by name" do
        delete "#{documents_path}/#{document.id}"
        expect(response).to have_http_status(:no_content)
        expect(ClientDocument.exists?(document.id)).to be(false)
        expect(AuditLog.where(record_type: "client_documents").last.subject_name).to eq(document.title)
      end

      it "returns scoped public document and conversation activity, excluding security and arbitrary metadata" do
        post "#{documents_path}/#{document.id}/opened"
        post "#{threads_path}/#{thread.id}/messages", params: { body: "Hello", idempotency_key: "activity" }
        AuditLog.record!(user: actor, company_id: company.id, action: "portal_documents#download", record_type: "client_documents", record_id: document.id,
          subject_name: "Forbidden security", event_category: "security", metadata: { token: "private" })
        get "#{documents_path}/#{document.id}/activity"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(document.title)
        expect(response.body).not_to include("ip_address", "user_agent", "actor_email", "Forbidden security", "private", "metadata")
        get "#{threads_path}/#{thread.id}/activity"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(thread.subject)
        expect(response.body).not_to include("Hello")
        other = create(:client_document)
        get "#{documents_path}/#{other.id}/activity"
        expect(response).to have_http_status(:not_found)
        if role == "client"
          hidden = create(:client_document, company: company, visible_to_client: false)
          get "#{documents_path}/#{hidden.id}/activity"
          expect(response).to have_http_status(:not_found)
        end
      end

      it "records explicit forbidden company context without exposing its name" do
        other = create(:company, name: "Unauthorized employer")
        get threads_path, headers: { "X-Company-Id" => other.id.to_s }
        expect(response).to have_http_status(:forbidden)
        failure = AuditLog.find_by!(action: "portal_access#failed")
        expect(failure.company_id).to be_nil
        expect(failure.to_json).not_to include(other.name)
      end

      it "records failed uploads and denies foreign document/thread mutations" do
        post documents_path, params: { title: "No files" }
        expect(response).to have_http_status(:unprocessable_entity)
        other = create(:client_document)
        delete "#{documents_path}/#{other.id}"
        expect(response).to have_http_status(:not_found)
        other_thread = create(:client_portal_thread)
        get "#{threads_path}/#{other_thread.id}"
        expect(response).to have_http_status(:not_found)
        patch "#{threads_path}/#{other_thread.id}", params: { status: "resolved" }
        expect(response).to have_http_status(:not_found)
        expect(AuditLog.where(action: "portal_access#failed").count).to eq(4)
      end

      it "records an employee name on uploaded evidence" do
        employee = create(:employee, company: company, first_name: "Maria", last_name: "Santos")
        post documents_path, params: { file: fixture_file_upload("client_portal_upload.txt", "text/plain"), title: "Maria W-4", employee_id: employee.id }
        expect(response).to have_http_status(:created)
        expect(AuditLog.where(record_type: "client_documents").last.metadata).to include("employee_name" => employee.full_name)
      end

      it "counts unread across paginated threads independently of loaded rows" do
        3.times do
          topic = create(:client_portal_thread, company: company)
          create(:client_portal_message, company: company, client_portal_thread: topic)
        end
        get threads_path, params: { per_page: 1 }
        expect(response.parsed_body.fetch("data").length).to eq(1)
        expect(response.parsed_body.fetch("meta")).to include("total_count" => 3, "unread_count" => 3)
      end

      it "tracks status success or denial and rolls staff decisions back on audit failure" do
        patch "#{threads_path}/#{thread.id}", params: { status: "resolved" }
        if role == "client"
          expect(response).to have_http_status(:forbidden)
          expect(AuditLog.find_by!(action: "portal_access#failed").metadata.fetch("status")).to eq(403)
          expect(thread.reload.status).to eq("open")
        else
          expect(response).to have_http_status(:ok)
          expect(AuditLog.find_by!(action: "client_portal_threads#resolved").subject_name).to eq(thread.subject)
          allow(AuditLog).to receive(:record!).and_call_original
          allow(AuditLog).to receive(:record!).with(hash_including(action: "client_portal_threads#reopened")).and_raise("audit down")
          expect { patch "#{threads_path}/#{thread.id}", params: { status: "open" } }.to raise_error("audit down")
          expect(thread.reload.status).to eq("resolved")
        end
      end
    end
  end
end
