# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice recurrence and scheduled email", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:profile) { create(:invoice_billing_profile, organization: company.organization) }
  let!(:recipient) { create(:invoice_recipient, organization: company.organization, company: nil, email: "customer@example.com") }

  before do
    [ Api::V1::Admin::InvoiceRecurrencesController, Api::V1::Admin::InvoiceSendSchedulesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin_user)
    end
  end

  after do
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("invoice-center"))
  end

  def issued_invoice
    invoice = create(:invoice, :with_line_item, company: company, organization: company.organization,
                    invoice_billing_profile: profile, invoice_recipient: recipient,
                    discount_type: "percent", discount_value: 10)
    InvoiceArtifactStorageService.new.issue_native!(invoice: invoice, actor: admin_user)
    invoice.reload
  end

  it "creates a separate draft for each due occurrence without duplicate numbers or drift" do
    source = issued_invoice
    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: source.id, start_on: "2026-01-31", interval_unit: "month", due_after_days: 14
    }
    expect(response).to have_http_status(:created), response.body
    recurrence = InvoiceRecurrence.find(response.parsed_body.dig("invoice_recurrence", "id"))

    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: source.id, start_on: "2026-01-31", interval_unit: "month"
    }
    expect(response).to have_http_status(:unprocessable_entity)

    InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 3, 31))
    drafts = recurrence.generated_invoices.order(:invoice_date).to_a
    expect(drafts.map(&:invoice_date)).to eq([ Date.new(2026, 1, 31), Date.new(2026, 2, 28), Date.new(2026, 3, 31) ])
    expect(drafts.map(&:invoice_number).uniq.size).to eq(3)
    expect(drafts.map(&:due_date)).to eq([ Date.new(2026, 2, 14), Date.new(2026, 3, 14), Date.new(2026, 4, 14) ])
    expect(drafts.map(&:total_amount)).to all(eq(270.to_d))
    expect(drafts.map(&:status)).to all(eq("draft"))
    expect(recurrence.reload.next_on).to eq(Date.new(2026, 4, 30))

    expect { InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 3, 31)) }.not_to change(Invoice, :count)
  end

  it "scopes scheduling to the organization and validates recipients" do
    source = issued_invoice
    other = create(:invoice, :with_line_item)

    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: other.id, start_on: "2026-10-01", interval_unit: "month"
    }
    expect(response).to have_http_status(:not_found)

    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id, recipients: [ "bad-address" ], send_at: "2026-10-01T09:00:00+10:00"
    }
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: other.id, recipients: [ "other@example.com" ], send_at: "2026-10-01T09:00:00+10:00"
    }
    expect(response).to have_http_status(:not_found)
  end

  it "sends one attached PDF to selected recipients and records provider acceptance" do
    source = issued_invoice
    InvoicePaymentService.record!(invoice: source, actor: admin_user, amount: 100, received_on: Date.current,
                                  payment_method: "check", currency: "USD")
    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id,
      recipients: [ "customer@example.com", "accounts@example.com" ],
      send_at: 1.minute.ago.iso8601
    }
    expect(response).to have_http_status(:created), response.body
    schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return("test-key")
    allow(ENV).to receive(:[]).with("INVOICE_MAILER_FROM_EMAIL").and_return("invoices@example.com")
    allow(Resend::Emails).to receive(:send).and_return({ id: "email-123" })

    InvoiceScheduledSender.send!(schedule.id)
    expect(schedule.reload).to have_attributes(status: "sent", provider_reference: "email-123")
    expect(source.reload.deliveries.pluck(:recipient)).to contain_exactly("customer@example.com", "accounts@example.com")
    expect(source.sent_at).to be_present
    expect(Resend::Emails).to have_received(:send).once do |message, options:|
      expect(message[:to]).to contain_exactly("customer@example.com", "accounts@example.com")
      expect(message[:attachments].sole[:content]).to be_an(Array)
      expect(message[:text]).to include("current balance is USD 170.00")
      expect(options[:idempotency_key]).to eq("invoice-send-#{schedule.id}")
    end
    expect { InvoiceScheduledSender.send!(schedule.id) }.not_to change(InvoiceDelivery, :count)
  end

  it "cancels pending email before a worker claims it" do
    source = issued_invoice
    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id, recipients: [ "customer@example.com" ], send_at: 1.minute.ago.iso8601
    }
    schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))

    patch "/api/v1/admin/invoice_send_schedules/#{schedule.id}", params: { cancel: true }
    expect(response).to have_http_status(:ok)
    expect(schedule.reload.status).to eq("cancelled")
    expect { InvoiceScheduledSender.send!(schedule.id) }.not_to change(InvoiceDelivery, :count)
  end

  it "flags an interrupted send for review without automatically sending again" do
    source = issued_invoice
    schedule = InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                           recipients: [ "customer@example.com" ], send_at: 2.hours.ago,
                                           status: "sending", claimed_at: 2.hours.ago)

    expect(InvoiceSendJob).not_to receive(:perform_later)
    InvoiceSendDispatchJob.new.perform

    expect(schedule.reload).to have_attributes(status: "failed", attempts: 0)
    expect(schedule.last_error).to include("verify provider delivery")
  end
end
