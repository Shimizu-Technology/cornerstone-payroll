# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice Center and accounts receivable API", type: :request do
  let!(:company) { create(:company, name: "Shimizu Technology") }
  let!(:sibling_company) { create(:company, organization: company.organization, name: "Payroll Client") }
  let!(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:recipient) { create(:invoice_recipient, organization: company.organization, company: nil, name: "Pacific Customer") }
  let!(:profile) do
    create(
      :invoice_billing_profile,
      organization: company.organization,
      name: "Shimizu Technology",
      invoice_prefix: "ST",
      is_default: true
    )
  end
  let(:active_company_id) { company.id }

  before do
    controllers = [
      Api::V1::Admin::InvoicesController,
      Api::V1::Admin::InvoicePaymentsController,
      Api::V1::Admin::InvoiceCreditNotesController,
      Api::V1::Admin::InvoiceReceivablesController,
      Api::V1::Admin::InvoiceRecipientsController
    ]
    controllers.each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin_user)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(active_company_id)
    end
  end

  after do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("invoice-center"))
  end

  it "owns recipients and invoices at the organization level instead of the active payroll client" do
    post "/api/v1/admin/invoice_recipients", params: { invoice_recipient: { name: "Organization Customer" } }

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("invoice_recipient", "company_id")).to be_nil

    invoice = create_draft
    expect(invoice.company_id).to be_nil

    get "/api/v1/admin/invoices", headers: { "X-Company-Id" => sibling_company.id.to_s }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("invoices").map { |row| row.fetch("id") }).to include(invoice.id)
  end

  it "allocates profile-specific numbers and issues an immutable PDF artifact" do
    first = create_draft(invoice_number: nil)
    second = create_draft(invoice_number: nil)

    expect(first.invoice_number).to eq("ST-2026-0001")
    expect(second.invoice_number).to eq("ST-2026-0002")

    post "/api/v1/admin/invoices/#{first.id}/issue"

    expect(response).to have_http_status(:ok)
    issued = first.reload
    artifact = issued.artifacts.sole
    bytes = R2StorageService.new.download(artifact.storage_key)
    expect(issued).to have_attributes(status: "open", issued_at: be_present)
    expect(artifact).to have_attributes(kind: "issued_pdf", content_type: "application/pdf")
    expect(Digest::SHA256.hexdigest(bytes)).to eq(artifact.sha256)
    expect(bytes).to start_with("%PDF")

    patch "/api/v1/admin/invoices/#{issued.id}", params: { invoice: { notes: "Changed after issue" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Issued invoice financial content is immutable")
  end

  it "reloads the locked draft before rendering the official artifact" do
    invoice = create_draft(total: 100)
    stale_invoice = Invoice.includes(:line_items).find(invoice.id)
    stale_invoice.line_items.load

    patch "/api/v1/admin/invoices/#{invoice.id}", params: {
      invoice: {
        line_items: [
          { id: invoice.line_items.sole.id, description: "Updated services", quantity: 2, rate: 125, position: 0 }
        ]
      }
    }
    expect(response).to have_http_status(:ok), response.body

    InvoiceArtifactStorageService.new.issue_native!(invoice: stale_invoice, actor: admin_user)

    snapshot = invoice.reload.snapshot
    expect(snapshot.dig("invoice", "total_amount")).to eq("250.0")
    expect(snapshot.dig("line_items", 0, "description")).to eq("Updated services")
    expect(snapshot.dig("line_items", 0, "rate")).to eq("125.0")
  end

  it "imports and preserves the exact original invoice with optional historical delivery evidence" do
    file = Tempfile.new([ "outside-invoice", ".pdf" ])
    file.binmode
    original = "%PDF-1.4\nexternal invoice evidence\n%%EOF\n"
    file.write(original)
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/pdf", original_filename: "outside invoice.pdf")

    post "/api/v1/admin/invoices/import", params: {
      file: upload,
      invoice_recipient_id: recipient.id,
      invoice_billing_profile_id: profile.id,
      invoice_number: "EXT-2048",
      invoice_date: "2026-06-01",
      due_date: "2026-06-15",
      total_amount: "850.25",
      delivered_at: "2026-06-01T09:30:00+10:00",
      delivery_channel: "email"
    }

    expect(response).to have_http_status(:created)
    invoice = Invoice.find(response.parsed_body.dig("invoice", "id"))
    artifact = invoice.artifacts.sole
    expect(invoice).to have_attributes(origin: "imported", status: "open", invoice_number: "EXT-2048")
    expect(invoice.reader_status(as_of: Date.new(2026, 6, 20))).to eq("overdue")
    expect(invoice.deliveries.sole.channel).to eq("email")
    expect(R2StorageService.new.download(artifact.storage_key)).to eq(original)
  ensure
    file&.close!
  end

  it "rolls back delivery, sent timestamp, and audit history together" do
    invoice = issue_invoice(total: 125)
    invalid_event = InvoiceEvent.new
    invalid_event.errors.add(:base, "Forced delivery audit failure")
    allow(InvoiceEvent).to receive(:record!).and_call_original
    allow(InvoiceEvent).to receive(:record!)
      .with(hash_including(invoice: have_attributes(id: invoice.id), event_type: "delivery_recorded"))
      .and_raise(ActiveRecord::RecordInvalid.new(invalid_event))

    expect do
      post "/api/v1/admin/invoices/#{invoice.id}/record_delivery", params: {
        channel: "email",
        recipient: "customer@example.com"
      }
    end.not_to change(InvoiceDelivery, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(invoice.reload.sent_at).to be_nil
    expect(invoice.events.where(event_type: "delivery_recorded")).to be_empty
  end

  it "tracks partial and final payments, rejects overpayment, and reverses without deleting evidence" do
    invoice = issue_invoice(total: 300)

    post "/api/v1/admin/invoices/#{invoice.id}/payments", params: {
      amount: 125,
      received_on: "2026-06-10",
      payment_method: "check",
      reference_number: "1042"
    }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("invoice", "status")).to eq("partially_paid")
    expect(response.parsed_body.dig("invoice", "balance_due")).to eq(175.0)

    post "/api/v1/admin/invoices/#{invoice.id}/payments", params: {
      amount: 176,
      received_on: "2026-06-11",
      payment_method: "cash"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Payment exceeds the remaining invoice balance")

    post "/api/v1/admin/invoices/#{invoice.id}/payments", params: {
      amount: 175,
      received_on: "2026-06-11",
      payment_method: "ach"
    }
    expect(response).to have_http_status(:created)
    payment_id = response.parsed_body.fetch("payment_id")
    expect(response.parsed_body.dig("invoice", "status")).to eq("paid")

    post "/api/v1/admin/invoices/#{invoice.id}/payments/#{payment_id}/reverse", params: { reason: "Returned ACH" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("invoice", "status")).to eq("partially_paid")
    expect(InvoicePayment.find(payment_id)).to have_attributes(reversed_at: be_present, reversal_reason: "Returned ACH")
  end

  it "applies and voids credits while preserving the credit-note history" do
    invoice = issue_invoice(total: 200)

    post "/api/v1/admin/invoices/#{invoice.id}/credit_notes", params: {
      amount: 50,
      issue_date: "2026-06-12",
      reason: "Service adjustment"
    }
    expect(response).to have_http_status(:created)
    credit_id = response.parsed_body.fetch("credit_note_id")
    expect(response.parsed_body.dig("invoice", "credit_total")).to eq(50.0)
    expect(response.parsed_body.dig("invoice", "balance_due")).to eq(150.0)

    post "/api/v1/admin/invoices/#{invoice.id}/credit_notes/#{credit_id}/void", params: { reason: "Issued in error" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("invoice", "credit_total")).to eq(0.0)
    expect(InvoiceCreditNote.find(credit_id)).to have_attributes(status: "voided", void_reason: "Issued in error")
  end

  it "derives aging, recipient balances, and statements from the same receivable ledger" do
    overdue = issue_invoice(total: 500, invoice_date: Date.new(2026, 5, 1), due_date: Date.new(2026, 5, 31))
    current = issue_invoice(total: 250, due_date: Date.new(2026, 7, 31))
    InvoicePaymentService.record!(
      invoice: overdue,
      actor: admin_user,
      amount: 100,
      received_on: Date.new(2026, 6, 1),
      payment_method: "check",
      currency: "USD"
    )

    get "/api/v1/admin/invoice_receivables", params: { as_of: "2026-07-01" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("totals", "outstanding")).to eq(650.0)
    expect(response.parsed_body.dig("totals", "overdue")).to eq(400.0)
    expect(response.parsed_body.dig("aging", "days_31_60")).to eq(400.0)
    expect(response.parsed_body.dig("aging", "current")).to eq(250.0)

    get "/api/v1/admin/invoice_receivables/statement", params: { recipient_id: recipient.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("outstanding")).to eq(650.0)
    expect(response.parsed_body.fetch("invoices").map { |row| row.fetch("id") }).to contain_exactly(overdue.id, current.id)
  end

  it "keeps archived receivables in financial totals but excludes uncollectible and voided balances" do
    archived = issue_invoice(total: 300)
    uncollectible = issue_invoice(total: 200)
    voided = issue_invoice(total: 100)
    draft = create_draft(invoice_number: "DRAFT-ONLY", total: 75)

    archived.archive!(actor: admin_user)
    uncollectible.mark_uncollectible!(actor: admin_user, reason: "Write-off")
    voided.void!(actor: admin_user, reason: "Duplicate")
    draft.archive!(actor: admin_user)

    get "/api/v1/admin/invoice_receivables", params: { as_of: "2026-07-01" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("totals", "outstanding")).to eq(300.0)
    expect(response.parsed_body.dig("totals", "open_count")).to eq(1)
    expect(response.parsed_body.dig("totals", "draft_count")).to eq(0)

    get "/api/v1/admin/invoice_receivables/statement", params: { recipient_id: recipient.id }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("outstanding")).to eq(300.0)
    expect(response.parsed_body.fetch("invoices").map { |row| row.fetch("id") }).to include(
      archived.id, uncollectible.id, voided.id, draft.id
    )
  end

  it "does not apply payments or credits after an invoice is written off as uncollectible" do
    invoice = issue_invoice(total: 200)
    invoice.mark_uncollectible!(actor: admin_user, reason: "Collection exhausted")

    post "/api/v1/admin/invoices/#{invoice.id}/payments", params: {
      amount: 25,
      received_on: "2026-06-10",
      payment_method: "check"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Uncollectible invoices cannot receive payments")

    post "/api/v1/admin/invoices/#{invoice.id}/credit_notes", params: {
      amount: 25,
      issue_date: "2026-06-10",
      reason: "Late adjustment"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Uncollectible invoices cannot receive credits")
    expect(invoice.reload).to have_attributes(balance_due: 200.to_d)
  end

  it "validates historical delivery data before an imported invoice is issued" do
    file = Tempfile.new([ "outside-invoice", ".pdf" ])
    file.write("%PDF-1.4\nexternal invoice evidence\n%%EOF\n")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/pdf", original_filename: "outside.pdf")

    expect do
      post "/api/v1/admin/invoices/import", params: {
        file: upload,
        invoice_recipient_id: recipient.id,
        invoice_billing_profile_id: profile.id,
        invoice_number: "EXT-BAD-DELIVERY",
        invoice_date: "2026-06-01",
        total_amount: "25.00",
        delivered_at: "2026-06-01T09:30:00+10:00",
        delivery_channel: "carrier_pigeon"
      }
    end.not_to change(Invoice, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Delivery channel is invalid")
  ensure
    file&.close!
  end

  it "requires evidence instead of allowing manual paid or sent status changes" do
    invoice = issue_invoice(total: 100)

    patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "paid" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join(" ")).to include("Record a payment or credit")

    patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "sent" }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join(" ")).to include("Record a delivery")
  end

  def create_draft(invoice_number: "TEST-100", total: 300, invoice_date: Date.new(2026, 6, 1), due_date: Date.new(2026, 6, 30))
    post "/api/v1/admin/invoices", params: {
      invoice: {
        invoice_recipient_id: recipient.id,
        invoice_billing_profile_id: profile.id,
        invoice_number: invoice_number,
        invoice_date: invoice_date.iso8601,
        due_date: due_date.iso8601,
        currency: "USD",
        line_items: [ { description: "Professional services", quantity: 1, rate: total, position: 0 } ]
      }
    }
    expect(response).to have_http_status(:created), response.body
    Invoice.find(response.parsed_body.dig("invoice", "id"))
  end

  def issue_invoice(total:, invoice_date: Date.new(2026, 6, 1), due_date: Date.new(2026, 6, 30))
    invoice = create_draft(invoice_number: "TEST-#{SecureRandom.hex(4)}", total: total, invoice_date: invoice_date, due_date: due_date)
    InvoiceArtifactStorageService.new.issue_native!(invoice: invoice, actor: admin_user)
    invoice.reload
  end
end
