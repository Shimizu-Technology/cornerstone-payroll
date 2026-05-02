# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice Chat Sessions Admin API", type: :request do
  let!(:company) { create(:company, name: "Invoice AI Client") }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "invoice-ai@example.com") }

  before do
    allow_any_instance_of(Api::V1::Admin::InvoiceChatSessionsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::InvoiceChatSessionsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "POST /api/v1/admin/invoice_chat_sessions" do
    it "creates a company-scoped assistant session" do
      post "/api/v1/admin/invoice_chat_sessions", params: { invoice_chat_session: { title: "May invoices" } }

      expect(response).to have_http_status(:created)
      body = response.parsed_body.fetch("invoice_chat_session")
      expect(body["title"]).to eq("May invoices")
      expect(body["company_id"]).to eq(company.id)
    end
  end

  describe "POST /api/v1/admin/invoice_chat_sessions/:id/message" do
    it "stores the user message, AI response, and structured preview" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      preview = {
        "status" => "preview",
        "message" => "Ready for review.",
        "invoice_recipient_id" => recipient.id,
        "invoice_recipient_name" => recipient.name,
        "invoice_date" => "2026-05-02",
        "line_items" => [
          { "description" => "Accounting service", "quantity" => 1, "rate" => 1000, "service_date" => nil }
        ]
      }
      service = instance_double(InvoiceAiPreviewService, call: preview)
      allow(InvoiceAiPreviewService).to receive(:new).and_return(service)

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/message", params: { content: "Invoice Shimizu Technology for $1,000" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body.fetch("invoice_chat_session")
      expect(body["current_preview"]).to include("invoice_recipient_id" => recipient.id)
      expect(body["messages"].map { |message| message["role"] }).to eq(%w[user assistant])
      expect(session.reload.current_preview_version).to eq(1)
    end

    it "rolls back the user message when preview persistence fails" do
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      service = instance_double(InvoiceAiPreviewService, call: { "status" => "clarification_needed", "message" => "More details needed.", "line_items" => [] })
      file = Tempfile.new([ "invoice-chat", ".jpg" ])
      file.binmode
      file.write("\xFF\xD8\xFF\xE0fakejpeg")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "image/jpeg")
      storage = instance_double(R2StorageService, delete: true)
      allow(InvoiceAiPreviewService).to receive(:new).and_return(service)
      allow(InvoiceAiAttachmentStorageService).to receive(:upload).and_return("invoice-assistant/company-1/session-1/upload.jpg")
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow_any_instance_of(InvoiceChatSession).to receive(:store_preview!).and_raise(ActiveRecord::RecordInvalid.new(session))

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/message",
        params: { content: "Invoice Shimizu Technology", images: [ upload ] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(session.messages.reload).to be_empty
      expect(storage).to have_received(:delete).with("invoice-assistant/company-1/session-1/upload.jpg")
    ensure
      file&.close
      file&.unlink
    end

    it "returns a validation error for unsupported attachment types" do
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      file = Tempfile.new([ "invoice-chat", ".txt" ])
      file.write("not an image or pdf")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "text/plain")

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/message",
        params: { content: "Use this attachment", images: [ upload ] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Unsupported attachment type")
      expect(session.messages.reload).to be_empty
    ensure
      file&.close
      file&.unlink
    end
  end

  describe "POST /api/v1/admin/invoice_chat_sessions/:id/confirm" do
    it "creates a draft invoice from the current preview" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        current_preview_version: 1,
        current_preview: {
          "status" => "preview",
          "invoice_recipient_id" => recipient.id,
          "invoice_date" => "2026-05-02",
          "payment_terms" => "Due on receipt",
          "email_subject" => "Invoice from Cornerstone Payroll",
          "line_items" => [
            { "description" => "Payroll service", "quantity" => 2, "rate" => 150, "service_date" => nil }
          ]
        }
      )

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"

      expect(response).to have_http_status(:created)
      invoice = Invoice.last
      expect(invoice.company_id).to eq(company.id)
      expect(invoice.invoice_recipient_id).to eq(recipient.id)
      expect(invoice.total_amount).to eq(300)
      expect(invoice.status).to eq("draft")
      expect(session.reload.invoice_id).to eq(invoice.id)
    end

    it "returns the existing invoice when the same preview is confirmed twice" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        current_preview_version: 1,
        current_preview: {
          "status" => "preview",
          "invoice_recipient_id" => recipient.id,
          "invoice_date" => "2026-05-02",
          "line_items" => [
            { "description" => "Payroll service", "quantity" => 2, "rate" => 150 }
          ]
        }
      )

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"
      expect(response).to have_http_status(:created)
      invoice_id = response.parsed_body.dig("invoice", "id")

      expect {
        post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"
      }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("invoice", "id")).to eq(invoice_id)
    end

    it "rejects inactive recipients in a preview" do
      recipient = create(:invoice_recipient, company: company, active: false)
      session = create(
        :invoice_chat_session,
        company: company,
        current_preview: {
          "invoice_recipient_id" => recipient.id,
          "invoice_date" => "2026-05-02",
          "line_items" => [
            { "description" => "Payroll service", "quantity" => 1, "rate" => 150 }
          ]
        }
      )

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invoice recipient not found")
    end

    it "does not create an invoice from an archived session" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        current_preview_version: 1,
        current_preview: {
          "status" => "preview",
          "invoice_recipient_id" => recipient.id,
          "invoice_date" => "2026-05-02",
          "line_items" => [
            { "description" => "Payroll service", "quantity" => 1, "rate" => 150 }
          ]
        }
      )
      session.archive!(actor: admin_user)

      expect {
        post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"
      }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Cannot confirm an archived session")
    end
  end
end
