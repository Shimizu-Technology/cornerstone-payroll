# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice Maker Admin API", type: :request do
  let!(:company) { create(:company, name: "Invoice Client") }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "invoice-maker@example.com") }

  before do
    allow_any_instance_of(Api::V1::Admin::InvoiceRecipientsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::InvoiceRecipientsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::InvoiceBillingProfilesController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::InvoiceBillingProfilesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::InvoicesController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::InvoicesController).to receive(:current_company_id).and_return(company.id)
  end

  describe "POST /api/v1/admin/invoice_recipients" do
    it "creates an invoice recipient" do
      post "/api/v1/admin/invoice_recipients",
        params: {
          invoice_recipient: {
            name: "Spectrio",
            email: "ap@spectrio.example",
            default_rate: 145,
            invoice_prefix: "SP",
            payment_terms: "Net 15"
          }
        }

      expect(response).to have_http_status(:created)
      body = response.parsed_body.fetch("invoice_recipient")
      expect(body["name"]).to eq("Spectrio")
      expect(body["default_rate"]).to eq(145.0)
    end
  end

  describe "POST /api/v1/admin/invoice_billing_profiles" do
    it "creates an organization-scoped billing profile" do
      post "/api/v1/admin/invoice_billing_profiles",
        params: {
          invoice_billing_profile: {
            name: "Shimizu Technology",
            legal_name: "Shimizu Technology",
            website: "https://shimizu-technology.com",
            phone: "671-483-0219",
            invoice_prefix: "ST",
            payment_instructions: "Please make checks payable to Shimizu Technology."
          }
        }

      expect(response).to have_http_status(:created)
      body = response.parsed_body.fetch("invoice_billing_profile")
      expect(body["name"]).to eq("Shimizu Technology")
      expect(body["organization_id"]).to eq(company.organization_id)
      expect(body["invoice_prefix"]).to eq("ST")
    end
  end

  describe "PATCH /api/v1/admin/invoice_billing_profiles/:id" do
    it "returns a validation error when default promotion hits a uniqueness race" do
      profile = create(:invoice_billing_profile, organization: company.organization, name: "Sender A")
      allow_any_instance_of(InvoiceBillingProfile).to receive(:update)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate default"))

      patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}",
        params: { invoice_billing_profile: { is_default: true } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to include("A billing profile with those settings already exists")
    end
  end

  describe "DELETE /api/v1/admin/invoice_billing_profiles/:id" do
    it "archives an in-use default profile and clears the default flag" do
      profile = create(:invoice_billing_profile, organization: company.organization, name: "Default Sender", is_default: true)
      recipient = create(:invoice_recipient, company: company)
      create(:invoice, :with_line_item, company: company, organization: company.organization, invoice_billing_profile: profile, invoice_recipient: recipient)

      delete "/api/v1/admin/invoice_billing_profiles/#{profile.id}"

      expect(response).to have_http_status(:ok)
      expect(profile.reload).to have_attributes(active: false, is_default: false)
      expect {
        InvoiceBillingProfile.ensure_default_for!(company.organization)
      }.to change(InvoiceBillingProfile, :count).by(1)
      expect(company.organization.invoice_billing_profiles.active.find_by(is_default: true)).to be_present
    end
  end

  describe "POST /api/v1/admin/invoices" do
    it "creates a draft invoice with line items and calculated total" do
      recipient = create(:invoice_recipient, company: company)
      billing_profile = create(:invoice_billing_profile, organization: company.organization, name: "Shimizu Technology", invoice_prefix: "ST")

      post "/api/v1/admin/invoices",
        params: {
          invoice: {
            invoice_recipient_id: recipient.id,
            invoice_billing_profile_id: billing_profile.id,
            invoice_number: "INV-1001",
            invoice_date: "2026-05-02",
            service_period_start: "2026-05-01",
            service_period_end: "2026-05-15",
            payment_terms: "Due on receipt",
            line_items: [
              {
                description: "Payroll processing",
                quantity: 2,
                rate: 150,
                position: 0
              },
              {
                description: "Bookkeeping",
                quantity: 1.5,
                rate: 80,
                position: 1
              }
            ]
          }
        }

      expect(response).to have_http_status(:created)
      body = response.parsed_body.fetch("invoice")
      expect(body["invoice_number"]).to eq("INV-1001")
      expect(body["invoice_billing_profile"]["name"]).to eq("Shimizu Technology")
      expect(body["total_amount"]).to eq(420.0)
      expect(body["line_items"].size).to eq(2)
    end

    it "rejects a billing profile from another organization" do
      recipient = create(:invoice_recipient, company: company)
      other_profile = create(:invoice_billing_profile)

      post "/api/v1/admin/invoices",
        params: {
          invoice: {
            invoice_recipient_id: recipient.id,
            invoice_billing_profile_id: other_profile.id,
            invoice_number: "INV-1002",
            invoice_date: "2026-05-02"
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invoice billing profile not found")
    end

    it "rejects a recipient from another company" do
      other_company = create(:company)
      other_recipient = create(:invoice_recipient, company: other_company)

      post "/api/v1/admin/invoices",
        params: {
          invoice: {
            invoice_recipient_id: other_recipient.id,
            invoice_number: "INV-1002",
            invoice_date: "2026-05-02"
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invoice recipient not found")
    end

    it "rejects archived recipients for new invoices" do
      recipient = create(:invoice_recipient, company: company, active: false)

      post "/api/v1/admin/invoices",
        params: {
          invoice: {
            invoice_recipient_id: recipient.id,
            invoice_number: "INV-1003",
            invoice_date: "2026-05-02",
            line_items: [
              {
                description: "Accounting service",
                quantity: 1,
                rate: 100,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invoice recipient is archived")
    end
  end

  describe "PATCH /api/v1/admin/invoices/:id" do
    it "blocks issued invoice edits" do
      invoice = create(:invoice, :with_line_item, :generated, company: company)

      patch "/api/v1/admin/invoices/#{invoice.id}",
        params: {
          invoice: {
            invoice_recipient_id: invoice.invoice_recipient_id,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date.iso8601,
            line_items: [
              {
                id: invoice.line_items.first.id,
                description: "Changed after generation",
                quantity: 5,
                rate: 500,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Issued invoice financial content is immutable")
      expect(invoice.line_items.first.reload.description).not_to eq("Changed after generation")
    end

    it "does not permit issued invoices to return to draft" do
      invoice = create(:invoice, :with_line_item, :generated, company: company)

      patch "/api/v1/admin/invoices/#{invoice.id}",
        params: {
          mark_draft: "true",
          invoice: {
            invoice_recipient_id: invoice.invoice_recipient_id,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date.iso8601,
            line_items: [
              {
                id: invoice.line_items.first.id,
                description: "Changed as draft",
                quantity: 1,
                rate: 25,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Issued invoice financial content is immutable")
      expect(invoice.reload.status).to eq("open")
      expect(invoice.line_items.first.reload.description).not_to eq("Changed as draft")
    end

    it "allows an invoice to keep its existing archived recipient" do
      recipient = create(:invoice_recipient, company: company, active: false)
      invoice = create(:invoice, :with_line_item, company: company, invoice_recipient: recipient)

      patch "/api/v1/admin/invoices/#{invoice.id}",
        params: {
          invoice: {
            invoice_recipient_id: recipient.id,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date.iso8601,
            notes: "Updated without repointing recipient",
            line_items: [
              {
                id: invoice.line_items.first.id,
                description: "Accounting service",
                quantity: 1,
                rate: 100,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:ok)
      expect(invoice.reload.invoice_recipient_id).to eq(recipient.id)
      expect(invoice.notes).to eq("Updated without repointing recipient")
    end

    it "rejects mark_draft when the status lifecycle does not allow returning to draft" do
      invoice = create(:invoice, :with_line_item, company: company, status: "voided", generated_at: 2.days.ago, voided_at: Time.current)

      patch "/api/v1/admin/invoices/#{invoice.id}",
        params: {
          mark_draft: "true",
          invoice: {
            invoice_recipient_id: invoice.invoice_recipient_id,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date.iso8601,
            notes: "Should not be accepted",
            line_items: [
              {
                id: invoice.line_items.first.id,
                description: "Accounting service",
                quantity: 1,
                rate: 100,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Issued invoice financial content is immutable")
      expect(invoice.reload.status).to eq("voided")
      expect(invoice.notes).not_to eq("Should not be accepted")
    end
  end

  describe "POST /api/v1/admin/invoices/:id/generate_pdf" do
    it "issues, stores, and downloads the invoice PDF" do
      invoice = create(:invoice, :with_line_item, company: company)

      post "/api/v1/admin/invoices/#{invoice.id}/generate_pdf"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(invoice.reload.status).to eq("open")
      expect(invoice.generated_at).to be_present
      expect(invoice.artifacts.sole.kind).to eq("issued_pdf")
    end

    it "returns validation errors before rendering when there are no line items" do
      invoice = create(:invoice, company: company)

      expect(InvoicePdfGenerator).not_to receive(:new)

      post "/api/v1/admin/invoices/#{invoice.id}/generate_pdf"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to include("Line items must include at least one line item")
      expect(invoice.reload.status).to eq("draft")
    end

    it "does not mark the invoice generated when PDF rendering fails" do
      invoice = create(:invoice, :with_line_item, company: company)
      allow_any_instance_of(InvoicePdfGenerator).to receive(:generate).and_raise(Prawn::Errors::CannotFit, "layout overflow")

      post "/api/v1/admin/invoices/#{invoice.id}/generate_pdf"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(invoice.reload.status).to eq("draft")
      expect(invoice.generated_at).to be_nil
      expect(invoice.snapshot).to eq({})
    end
  end

  describe "PATCH /api/v1/admin/invoices/:id/update_status" do
    it "rejects manually marking an invoice paid" do
      invoice = create(:invoice, :with_line_item, :generated, company: company)

      patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "paid" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join(" ")).to include("Record a payment or credit")
      expect(invoice.reload.status).to eq("open")
    end

    it "rejects manually marking an invoice sent" do
      invoice = create(:invoice, :with_line_item, :generated, company: company)

      patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "sent" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join(" ")).to include("Record a delivery")
      expect(invoice.reload.status).to eq("open")
    end
  end
end
