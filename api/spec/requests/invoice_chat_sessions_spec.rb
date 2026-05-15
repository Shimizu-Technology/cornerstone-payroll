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

    it "allows a recipient from another company in the same organization" do
      other_company = create(:company, organization: company.organization)
      recipient = create(:invoice_recipient, company: other_company, organization: company.organization)

      post "/api/v1/admin/invoice_chat_sessions",
        params: { invoice_chat_session: { title: "Org recipient", invoice_recipient_id: recipient.id } }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("invoice_chat_session", "invoice_recipient_id")).to eq(recipient.id)
    end

    it "allows a linked invoice from another company in the same organization" do
      other_company = create(:company, organization: company.organization)
      recipient = create(:invoice_recipient, company: other_company, organization: company.organization)
      invoice = create(:invoice, :with_line_item, company: other_company, organization: company.organization, invoice_recipient: recipient)

      session = build(:invoice_chat_session, company: company, invoice: invoice, invoice_recipient: recipient)

      expect(session).to be_valid
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

    it "continues the chat on a previously completed session" do
      original_preview = { "status" => "preview", "message" => "Original preview." }
      next_preview = { "status" => "preview", "message" => "New preview." }
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        status: "invoice_created",
        current_preview: original_preview,
        current_preview_version: 1
      )
      service = instance_double(InvoiceAiPreviewService, call: next_preview)
      allow(InvoiceAiPreviewService).to receive(:new).and_return(service)

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/message",
        params: { content: "Change this invoice" }

      expect(response).to have_http_status(:ok)
      expect(session.messages.reload.size).to eq(2)
      expect(session.reload.status).to eq("active")
      expect(session.current_preview).to eq(next_preview)
      expect(session.current_preview_version).to eq(2)
    end

    it "cleans up uploaded attachments on unexpected failures before persistence" do
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      file = Tempfile.new([ "invoice-chat", ".jpg" ])
      file.binmode
      file.write("\xFF\xD8\xFF\xE0fakejpeg")
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "image/jpeg")
      storage = instance_double(R2StorageService, delete: true)
      allow(InvoiceAiAttachmentStorageService).to receive(:upload).and_return("invoice-assistant/company-1/session-1/upload.jpg")
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow(InvoiceAiPreviewService).to receive(:new).and_raise(StandardError, "unexpected")

      expect {
        post "/api/v1/admin/invoice_chat_sessions/#{session.id}/message",
          params: { content: "Invoice Shimizu Technology", images: [ upload ] }
      }.to raise_error(StandardError, "unexpected")

      expect(storage).to have_received(:delete).with("invoice-assistant/company-1/session-1/upload.jpg")
      expect(session.messages.reload).to be_empty
    ensure
      file&.close
      file&.unlink
    end
  end

  describe "POST /api/v1/admin/invoice_chat_sessions/:id/restore_preview" do
    it "restores a prior assistant preview onto an active session" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      preview = {
        "status" => "preview",
        "message" => "Ready for review.",
        "invoice_recipient_id" => recipient.id,
        "invoice_recipient_name" => recipient.name,
        "line_items" => [
          { "description" => "Payroll service", "quantity" => 1, "rate" => 150 }
        ]
      }
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      message = create(
        :invoice_chat_message,
        invoice_chat_session: session,
        role: "assistant",
        preview: preview,
        preview_version: 1,
        has_preview: true
      )

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/restore_preview",
        params: { message_id: message.id }

      expect(response).to have_http_status(:ok)
      expect(session.reload.current_preview).to include("invoice_recipient_id" => recipient.id)
      expect(session.current_preview_version).to eq(1)
      expect(session.messages.where(role: "assistant").last.content).to eq("Restored invoice preview version 1.")
    end
  end

  describe "POST /api/v1/admin/invoice_chat_sessions/:id/restore" do
    it "restores an archived assistant session to active" do
      session = create(:invoice_chat_session, company: company, created_by: admin_user, updated_by: admin_user)
      session.archive!(actor: admin_user)

      post "/api/v1/admin/invoice_chat_sessions/#{session.id}/restore"

      expect(response).to have_http_status(:ok)
      expect(session.reload).to have_attributes(archived: false, status: "active")
    end
  end

  describe "POST /api/v1/admin/invoice_chat_sessions/:id/confirm" do
    it "creates a draft invoice from the current preview" do
      recipient = create(:invoice_recipient, company: company, name: "Shimizu Technology")
      billing_profile = create(:invoice_billing_profile, organization: company.organization, name: "Shimizu Technology", invoice_prefix: "ST")
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        current_preview_version: 1,
        current_preview: {
          "status" => "preview",
          "invoice_billing_profile_id" => billing_profile.id,
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
      expect(invoice.invoice_billing_profile_id).to eq(billing_profile.id)
      expect(invoice.total_amount).to eq(300)
      expect(invoice.status).to eq("draft")
      expect(session.reload.invoice_id).to eq(invoice.id)
      expect(session.messages.last.preview).to include(
        "created_invoice_id" => invoice.id,
        "created_invoice_number" => invoice.invoice_number
      )
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

    it "finds an already-created preview invoice across companies in the same organization" do
      other_company = create(:company, organization: company.organization)
      recipient = create(:invoice_recipient, company: other_company, organization: company.organization, name: "Shimizu Technology")
      invoice = create(:invoice, :with_line_item, company: other_company, organization: company.organization, invoice_recipient: recipient)
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
      session.update_column(:invoice_id, invoice.id)
      session.messages.create!(
        role: "assistant",
        content: "Invoice is ready.",
        preview: session.current_preview.merge(
          "created_invoice_id" => invoice.id,
          "created_invoice_number" => invoice.invoice_number
        ),
        preview_version: session.current_preview_version,
        has_preview: true
      )

      expect {
        post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"
      }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("invoice", "id")).to eq(invoice.id)
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

    it "creates a recipient when the preview includes a new bill-to profile" do
      session = create(
        :invoice_chat_session,
        company: company,
        created_by: admin_user,
        updated_by: admin_user,
        current_preview_version: 1,
        current_preview: {
          "status" => "preview",
          "invoice_recipient_id" => nil,
          "invoice_recipient_name" => "Pacific Tech",
          "new_recipient" => {
            "name" => "Pacific Tech",
            "email" => "billing@pacific.example",
            "payment_terms" => "Due on receipt",
            "template_type" => "hourly"
          },
          "invoice_date" => "2026-05-02",
          "line_items" => [
            { "description" => "Accounting service", "quantity" => 2, "rate" => 125 }
          ]
        }
      )

      expect {
        post "/api/v1/admin/invoice_chat_sessions/#{session.id}/confirm"
      }.to change(InvoiceRecipient, :count).by(1)
        .and change(Invoice, :count).by(1)

      expect(response).to have_http_status(:created)
      recipient = InvoiceRecipient.last
      invoice = Invoice.last
      expect(recipient).to have_attributes(
        company_id: company.id,
        name: "Pacific Tech",
        email: "billing@pacific.example",
        payment_terms: "Due on receipt",
        template_type: "hourly",
        active: true
      )
      expect(invoice.invoice_recipient_id).to eq(recipient.id)
      expect(invoice.total_amount).to eq(250)
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
