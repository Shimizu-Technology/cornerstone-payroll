# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice recurrence and scheduled email", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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

  it "rejects a blank recurrence time zone without raising" do
    source = issued_invoice
    recurrence = InvoiceRecurrence.new(organization: source.organization, source_invoice: source,
                                       start_on: Date.current, next_on: Date.current, interval_unit: "month",
                                       interval_count: 1, due_after_days: 30, time_zone: nil)

    expect(recurrence).not_to be_valid
    expect(recurrence.errors[:time_zone]).to include("is invalid")
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

  it "stops at the end date and cannot be resumed past it" do
    source = issued_invoice
    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: source.id, start_on: "2026-01-31", ends_on: "2026-02-28", interval_unit: "month"
    }
    recurrence = InvoiceRecurrence.find(response.parsed_body.dig("invoice_recurrence", "id"))

    InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 3, 31))
    expect(recurrence.reload).to have_attributes(active: false, next_on: Date.new(2026, 3, 31))
    expect(recurrence.generated_invoices.count).to eq(2)

    patch "/api/v1/admin/invoice_recurrences/#{recurrence.id}", params: { active: true }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(recurrence.reload).not_to be_active
    expect { InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 3, 31)) }.not_to change(Invoice, :count)
  end

  it "resumes a paused recurrence at its next future occurrence" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9) do
      source = issued_invoice
      post "/api/v1/admin/invoice_recurrences", params: {
        source_invoice_id: source.id, start_on: "2026-07-01", interval_unit: "month"
      }
      recurrence = InvoiceRecurrence.find(response.parsed_body.dig("invoice_recurrence", "id"))

      patch "/api/v1/admin/invoice_recurrences/#{recurrence.id}", params: { active: false }
      expect(response).to have_http_status(:ok)
      patch "/api/v1/admin/invoice_recurrences/#{recurrence.id}", params: { active: true }

      expect(response).to have_http_status(:ok)
      expect(recurrence.reload).to be_active
      expect(recurrence.next_on).to eq(Date.new(2026, 11, 1))
      expect(recurrence.occurrence_index).to eq(4)
      expect { InvoiceRecurrenceGenerator.generate_due! }.not_to change(Invoice, :count)
    end
  end

  it "deactivates a voided source without blocking other recurring drafts" do
    voided_source = issued_invoice
    valid_source = issued_invoice
    [ voided_source, valid_source ].each do |source|
      post "/api/v1/admin/invoice_recurrences", params: {
        source_invoice_id: source.id, start_on: "2026-09-01", interval_unit: "month"
      }
      expect(response).to have_http_status(:created)
    end
    voided_source.void!(actor: admin_user, reason: "No longer billable")

    InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 9, 28))

    expect(InvoiceRecurrence.find_by!(source_invoice: voided_source)).not_to be_active
    expect(InvoiceRecurrence.find_by!(source_invoice: valid_source).generated_invoices.count).to eq(1)
  end

  it "rejects an unusable source and isolates a damaged existing recurrence" do
    damaged_source = issued_invoice
    valid_source = issued_invoice
    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: damaged_source.id, start_on: "2026-09-01", interval_unit: "month"
    }
    expect(response).to have_http_status(:created)
    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: valid_source.id, start_on: "2026-09-01", interval_unit: "month"
    }
    expect(response).to have_http_status(:created)

    damaged_source.update_column(:snapshot, {})
    InvoiceRecurrenceGenerator.generate_due!(today: Date.new(2026, 9, 28))

    expect(InvoiceRecurrence.find_by!(source_invoice: damaged_source)).not_to be_active
    expect(InvoiceRecurrence.find_by!(source_invoice: valid_source).generated_invoices.count).to eq(1)

    post "/api/v1/admin/invoice_recurrences", params: {
      source_invoice_id: damaged_source.id, start_on: "2026-10-01", interval_unit: "month"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("usable template")
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

  it "queues an immediate invoice email with a durable schedule" do
    source = issued_invoice
    allow(InvoiceSendJob).to receive(:perform_later)

    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id, recipients: [ "customer@example.com" ], send_now: true
    }

    expect(response).to have_http_status(:created), response.body
    schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))
    expect(schedule).to have_attributes(status: "pending", recipients: [ "customer@example.com" ])
    expect(schedule.send_at).to be_within(10.seconds).of(Time.current)
    expect(InvoiceSendJob).to have_received(:perform_later).with(schedule.id)
  end

  it "retains an immediate email for the dispatcher when enqueue fails" do
    source = issued_invoice
    allow(InvoiceSendJob).to receive(:perform_later).and_raise("queue unavailable")

    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id, recipients: [ "customer@example.com" ], send_now: true
    }

    expect(response).to have_http_status(:created), response.body
    expect(InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id")).status).to eq("pending")
  end

  it "retries with the same email payload after the invoice balance changes" do
    source = issued_invoice
    post "/api/v1/admin/invoice_send_schedules", params: {
      invoice_id: source.id, recipients: [ "customer@example.com" ], send_at: 1.minute.ago.iso8601
    }
    schedule = InvoiceSendSchedule.find(response.parsed_body.dig("invoice_send_schedule", "id"))

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("RESEND_API_KEY").and_return("test-key")
    allow(ENV).to receive(:[]).with("INVOICE_MAILER_FROM_EMAIL").and_return("invoices@example.com")
    messages = []
    allow(Resend::Emails).to receive(:send) do |message, options:|
      messages << [ message, options ]
      raise "provider response lost" if messages.size == 1

      { id: "email-after-retry" }
    end

    expect { InvoiceScheduledSender.send!(schedule.id) }.to raise_error("provider response lost")
    expect(schedule.reload.status).to eq("failed")
    original_body = schedule.rendered_body
    InvoicePaymentService.record!(invoice: source, actor: admin_user, amount: 100, received_on: Date.current,
                                  payment_method: "check", currency: "USD")

    patch "/api/v1/admin/invoice_send_schedules/#{schedule.id}", params: { retry: true }
    expect(response).to have_http_status(:ok)
    patch "/api/v1/admin/invoice_send_schedules/#{schedule.id}", params: { recipients: [ "other@example.com" ] }
    expect(response).to have_http_status(:unprocessable_entity)

    InvoiceScheduledSender.send!(schedule.id)
    expect(schedule.reload).to have_attributes(status: "sent", rendered_body: original_body)
    expect(messages.map { |message, _| message[:text] }).to eq([ original_body, original_body ])
    expect(messages.map { |message, _| message[:to] }).to eq([ [ "customer@example.com" ], [ "customer@example.com" ] ])
    expect(messages.map { |_, options| options[:idempotency_key] }.uniq).to eq([ "invoice-send-#{schedule.id}" ])
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

  it "claims due emails once so delayed jobs do not block later schedules" do
    source = issued_invoice
    schedules = 101.times.map do |index|
      InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                  recipients: [ "customer@example.com" ], send_at: (101 - index).minutes.ago)
    end
    allow(InvoiceSendJob).to receive(:perform_later)

    InvoiceSendDispatchJob.new.perform
    expect(schedules.first(100).map { |schedule| schedule.reload.status }.uniq).to eq([ "queued" ])
    expect(schedules.last.reload.status).to eq("pending")

    InvoiceSendDispatchJob.new.perform
    expect(schedules.last.reload.status).to eq("queued")
    expect(InvoiceSendJob).to have_received(:perform_later).exactly(101).times
  end

  it "returns a claimed email to pending if enqueueing fails" do
    source = issued_invoice
    schedule = InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                           recipients: [ "customer@example.com" ], send_at: 1.minute.ago)
    allow(InvoiceSendJob).to receive(:perform_later).and_raise("queue unavailable")

    expect { InvoiceSendDispatchJob.new.perform }.to raise_error("queue unavailable")
    expect(schedule.reload.status).to eq("pending")
  end

  it "requeues an abandoned dispatch claim" do
    source = issued_invoice
    schedule = InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                           recipients: [ "customer@example.com" ], send_at: 15.minutes.ago,
                                           status: "queued")
    schedule.update_columns(updated_at: 11.minutes.ago)
    allow(InvoiceSendJob).to receive(:perform_later)

    InvoiceSendDispatchJob.new.perform

    expect(schedule.reload.status).to eq("queued")
    expect(InvoiceSendJob).to have_received(:perform_later).with(schedule.id).once
  end

  it "does not requeue a schedule while its Solid Queue job is waiting" do
    source = issued_invoice
    schedule = InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                           recipients: [ "customer@example.com" ], send_at: 15.minutes.ago,
                                           status: "queued")
    schedule.update_columns(updated_at: 11.minutes.ago)
    SolidQueue::Job.create!(class_name: "InvoiceSendJob", queue_name: "default",
                            arguments: InvoiceSendJob.new(schedule.id).serialize)
    expect(InvoiceSendJob).not_to receive(:perform_later)

    InvoiceSendDispatchJob.new.perform

    expect(schedule.reload.status).to eq("queued")
  end

  it "refuses a retry after the provider idempotency window expires" do
    source = issued_invoice
    schedule = InvoiceSendSchedule.create!(organization: source.organization, invoice: source,
                                           recipients: [ "customer@example.com" ], send_at: 26.hours.ago,
                                           status: "failed", attempts: 1, claimed_at: 25.hours.ago,
                                           first_claimed_at: 25.hours.ago)

    patch "/api/v1/admin/invoice_send_schedules/#{schedule.id}", params: { retry: true }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("idempotency window has expired")
    expect(schedule.reload.status).to eq("failed")
  end
end
