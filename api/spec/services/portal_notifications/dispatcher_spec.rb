# frozen_string_literal: true

require "rails_helper"

RSpec.describe PortalNotifications::Dispatcher, :portal_notifications do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, name: "Sensitive Bistro LLC") }
  let(:client) { create(:user, company: company, role: "client", name: "Casey Client") }
  let(:staff) { create(:user, company: company, role: "admin", email: "staff.reviewer@example.test") }
  let(:thread) { create(:client_portal_thread, company: company, created_by: client, subject: "Garnishment for Jordan Reyes") }
  let(:secret_body) { "SSN 123-45-6789, routing 021000021, account 9876543210 for Jordan Reyes" }

  before { list_portal_recipient!(company, user: staff) }

  def client_message!(body: secret_body)
    message = create(:client_portal_message, client_portal_thread: thread, company: company, author: client, body: body)
    PortalNotifications.message_created!(message)
  end

  def deliveries_for(user)
    PortalNotificationDelivery.where(user: user).order(:id)
  end

  def dispatch_at(time)
    travel_to(time) { described_class.run! }
  end

  it "keeps real email off by default and records the skip when the activity happens" do
    with_portal_email(enabled: false) { client_message! }
    expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "email_delivery_disabled", delivery_mode: "immediate")

    dispatch_at(3.minutes.from_now)

    expect(Resend::Emails).not_to have_received(:send)
    expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "email_delivery_disabled")
  end

  it "never sends activity recorded while email was off after email is turned on" do
    list_portal_recipient!(company, email: "outside.owner@example.test")
    with_portal_email(enabled: false) do
      client_message!
      PortalNotifications.client_upload!(documents: [ create(:client_document, company: company) ], actor: client)
    end
    before_enabling = PortalNotificationDelivery.where(company: company).pluck(:id)
    expect(PortalNotificationDelivery.where(id: before_enabling).pluck(:status).uniq).to eq([ "skipped" ])

    with_portal_email do
      dispatch_at(3.minutes.from_now)
      dispatch_at(1.day.from_now)
      expect(captured_portal_emails).to be_empty
      expect(PortalNotificationDelivery.where(id: before_enabling).pluck(:skip_reason).uniq).to eq([ "email_delivery_disabled" ])

      later_thread = create(:client_portal_thread, company: company, created_by: client, subject: "After enabling")
      PortalNotifications.message_created!(create(:client_portal_message, client_portal_thread: later_thread, company: company, author: client))
      dispatch_at(3.minutes.from_now)
      expect(captured_portal_emails.map { |email| email[:to] }).to contain_exactly(staff.email, "outside.owner@example.test")
    end
  end

  it "waits for the batch window, then sends one generic email for a burst of activity" do
    with_portal_email do
      client_message!
      second_thread = create(:client_portal_thread, company: company, created_by: client, subject: "Second topic")
      PortalNotifications.message_created!(create(:client_portal_message, client_portal_thread: second_thread, company: company, author: client))

      dispatch_at(1.minute.from_now)
      expect(captured_portal_emails).to be_empty

      dispatch_at(3.minutes.from_now)
      expect(captured_portal_emails.size).to eq(1)
      email = captured_portal_emails.sole
      expect(email).to include(to: "staff.reviewer@example.test", from: %("Cornerstone Payroll" <alerts@example.test>),
        subject: "Portal update — #{company.name}")
      expect(email[:text]).to include("You have a new message in the portal.", "Sign in to view it.",
        "https://payroll.example.test/companies/#{company.id}/client-messages")
      expect(deliveries_for(staff).pluck(:status, :attempts, :batch_key).uniq).to eq([ [ "sent", 1, email[:idempotency_key] ] ])
      expect(deliveries_for(staff).first.provider_message_id).to start_with("captured-")

      dispatch_at(5.minutes.from_now)
      expect(captured_portal_emails.size).to eq(1)
    end
  end

  it "sends payroll work in its own email so each link reaches the work it mentions" do
    with_portal_email do
      client_message!
      period = PayrollSubmissionPeriod.create!(company: company, start_date: Date.new(2026, 10, 19), end_date: Date.new(2026, 11, 1), source: "schedule")
      PortalNotifications.payroll_period!("payroll_draft_decided", period: period, actor: client, dedupe: "mixed-batch")

      dispatch_at(3.minutes.from_now)
      links = captured_portal_emails.map { |email| email[:text][%r{https://\S+}] }
      expect(links).to contain_exactly("https://payroll.example.test/companies/#{company.id}/client-messages",
        "https://payroll.example.test/companies/#{company.id}/payroll-submissions")
      expect(deliveries_for(staff).pluck(:status).uniq).to eq([ "sent" ])
    end
  end

  it "never puts names, subjects, bodies, file names or identifiers in the email or logs" do
    document = create(:client_document, company: company, title: "Jordan Reyes W-4 scan", file_name: "jordan-reyes-ssn.pdf")
    with_portal_email do
      client_message!
      PortalNotifications.client_upload!(documents: [ document ], actor: client)
      log = StringIO.new
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))

      dispatch_at(3.minutes.from_now)

      expect(captured_portal_emails.size).to eq(2)
      content = captured_portal_emails.map { |email| email.values_at(:subject, :text, :html).join }.join
      forbidden = [ thread.subject, secret_body, "123-45-6789", "021000021", "9876543210",
        "Jordan", document.title, document.file_name, "document_id", "thread_id" ]
      forbidden.each { |value| expect(content).not_to include(value) }
      expect(content).to include("You have a new message or update in the portal.", company.name)
      (forbidden + [ staff.email, client.name, company.name ]).each { |value| expect(log.string).not_to include(value) }
      expect(log.string).to include("[PortalNotification] accepted")
    end
  end

  it "uses Guam time for daily digest boundaries" do
    expect(PortalNotifications.next_digest_at(Time.utc(2026, 11, 11, 20, 30))).to eq(Time.utc(2026, 11, 11, 21, 0))
    expect(PortalNotifications.next_digest_at(Time.utc(2026, 11, 11, 21, 0))).to eq(Time.utc(2026, 11, 12, 21, 0))
    expect(PortalNotifications.next_digest_at(Time.utc(2026, 11, 11, 23, 0))).to eq(Time.utc(2026, 11, 12, 21, 0))
    expect(PortalNotifications.next_digest_at(Time.utc(2026, 11, 11, 20, 59, 59))).to eq(Time.utc(2026, 11, 11, 21, 0))
  end

  it "holds digest alerts until the 7 AM Chamorro Time boundary and sends the digest wording" do
    PortalNotificationPreference.create!(user: staff, category: "client_messages", delivery_mode: "digest")
    with_portal_email do
      travel_to(Time.utc(2026, 12, 1, 20, 30)) { client_message! }
      expect(deliveries_for(staff).sole.deliver_after).to eq(Time.utc(2026, 12, 1, 21, 0))

      dispatch_at(Time.utc(2026, 12, 1, 20, 59))
      expect(captured_portal_emails).to be_empty
      dispatch_at(Time.utc(2026, 12, 1, 21, 0))
      expect(captured_portal_emails.sole[:subject]).to include("Daily portal digest", company.name)
    end
  end

  it "records preference-off and coalesced alerts instead of sending" do
    with_portal_email do
      client_message!
      client_message!(body: "Second message in the same conversation")
      expect(deliveries_for(staff).pluck(:status, :skip_reason)).to eq([ [ "pending", nil ], [ "skipped", "coalesced" ] ])

      PortalNotificationPreference.create!(user: staff, category: "client_uploads", delivery_mode: "off")
      PortalNotifications.client_upload!(documents: [ create(:client_document, company: company) ], actor: client)
      expect(deliveries_for(staff).last).to have_attributes(status: "skipped", skip_reason: "preference_off")
    end
  end

  it "skips a still-pending alert once the person has read the conversation" do
    with_portal_email do
      client_message!
      thread.mark_read_for!(staff, displayed_message_ids: thread.messages.pluck(:id))
      dispatch_at(3.minutes.from_now)
      expect(captured_portal_emails).to be_empty
      expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "already_read")
    end
  end

  it "re-checks the list and access before each retry" do
    removed = create(:user, company: company, role: "admin")
    deactivated = create(:user, company: company, role: "admin")
    list_portal_recipient!(company, user: removed)
    list_portal_recipient!(company, user: deactivated)
    list_portal_recipient!(company, email: "outside.bookkeeper@example.test")
    with_portal_email do
      client_message!
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(Timeout::Error)
      dispatch_at(3.minutes.from_now)
      expect(PortalNotificationDelivery.where(company: company).pluck(:status, :attempts, :last_error_class).uniq).to eq([ [ "pending", 1, "Timeout::Error" ] ])

      PortalNotificationRecipient.where(user: removed).delete_all
      PortalNotificationRecipient.where(email: "outside.bookkeeper@example.test").delete_all
      deactivated.update!(active: false)
      allow(PortalNotifications::Transport).to receive(:deliver).and_call_original
      dispatch_at(10.minutes.from_now)

      expect(deliveries_for(removed).sole).to have_attributes(status: "skipped", skip_reason: "recipient_removed")
      expect(PortalNotificationDelivery.find_by!(recipient_email: "outside.bookkeeper@example.test"))
        .to have_attributes(status: "skipped", skip_reason: "recipient_removed")
      expect(deliveries_for(deactivated).sole).to have_attributes(status: "skipped", skip_reason: "access_revoked")
      expect(deliveries_for(staff).sole).to have_attributes(status: "sent", attempts: 2)
      expect(captured_portal_emails.map { |email| email[:to] }).to eq([ staff.email ])
    end
  end

  it "sends the generic email to extra addresses without app accounts" do
    list_portal_recipient!(company, email: "owner.phone@example.test")
    with_portal_email do
      client_message!
      dispatch_at(3.minutes.from_now)
      outside = captured_portal_emails.find { |email| email[:to] == "owner.phone@example.test" }
      expect(outside[:text]).to include("You have a new message in the portal.")
      expect(outside[:text]).not_to include(thread.subject, secret_body, "account menu")
      expect(outside[:text]).to include("Contact Cornerstone to change who receives these alerts.")
      staff_email = captured_portal_emails.find { |email| email[:to] == staff.email }
      expect(staff_email[:text]).to include("under Notifications in your account menu")
    end
  end

  it "backs off after transport failures and stops as failed after the last attempt" do
    with_portal_email do
      client_message!
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(StandardError, "provider echoed #{staff.email}")
      start = 3.minutes.from_now
      dispatch_at(start)
      row = deliveries_for(staff).sole
      expect(row.next_attempt_at).to be_within(1.second).of(start + 1.minute)

      dispatch_at(start + 30.seconds)
      expect(row.reload.attempts).to eq(1)

      waits = [ 1.minute, 5.minutes, 30.minutes, 2.hours ]
      at = start
      waits.each do |wait|
        at += wait
        dispatch_at(at)
      end
      expect(row.reload).to have_attributes(status: "failed", attempts: 5, last_error_class: "StandardError", next_attempt_at: nil)
      dispatch_at(at + 1.day)
      expect(row.reload.attempts).to eq(5)
    end
  end

  it "reuses the batch idempotency key when an interrupted claim is retried" do
    with_portal_email do
      client_message!
      at = 3.minutes.from_now
      PortalNotificationDelivery.update_all(claimed_at: at, batch_key: "portal-notification-interrupted", attempts: 1)
      dispatch_at(at + 5.minutes)
      expect(captured_portal_emails).to be_empty

      dispatch_at(at + 11.minutes)
      key = captured_portal_emails.sole[:idempotency_key]
      travel_to(at + 12.minutes) do
        PortalNotificationDelivery.update_all(status: "pending", claimed_at: 20.minutes.ago)
        described_class.run!
      end
      expect(captured_portal_emails.map { |email| email[:idempotency_key] }).to eq([ key, key ])
    end
  end

  it "suppresses a partially revoked branded batch after an ambiguous provider response" do
    documents = create_list(:client_document, 2, company: company)
    with_portal_email do
      documents.each { |document| PortalNotifications.client_upload!(documents: [ document ], actor: client) }
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(Timeout::Error)
      dispatch_at(3.minutes.from_now)
      expect(deliveries_for(staff).pluck(:status, :attempts).uniq).to eq([ [ "pending", 1 ] ])

      documents.first.update_columns(archived_at: Time.current)
      dispatch_at(10.minutes.from_now)

      expect(PortalNotifications::Transport).to have_received(:deliver).once
      expect(deliveries_for(staff).pluck(:status, :skip_reason)).to contain_exactly(
        [ "skipped", "resource_unavailable" ], [ "skipped", "access_revoked" ])
    end
  end

  it "does not send anything when every row of an attempted batch is revoked" do
    with_portal_email do
      client_message!
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(Timeout::Error)
      dispatch_at(3.minutes.from_now)
      PortalNotificationRecipient.where(user: staff).delete_all
      allow(PortalNotifications::Transport).to receive(:deliver).and_call_original
      dispatch_at(10.minutes.from_now)
      expect(captured_portal_emails).to be_empty
      expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "recipient_removed")
    end
  end

  it "records staging containment instead of treating it as delivered" do
    with_portal_email(transport: nil) do
      allow(StagingOutboundPolicy).to receive(:staging?).and_return(true)
      allow(StagingMailTransport).to receive(:deliver).and_return({ "id" => "staging-captured", "staging_captured" => true })
      client_message!
      dispatch_at(3.minutes.from_now)
      expect(StagingMailTransport).to have_received(:deliver).with(hash_including(to: staff.email), options: hash_including(:idempotency_key))
      expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "staging_contained")
    end
  end

  it "skips when delivery is enabled but email is not configured" do
    with_portal_email(transport: nil, from: nil) do
      client_message!
      dispatch_at(3.minutes.from_now)
      expect(Resend::Emails).not_to have_received(:send)
      expect(deliveries_for(staff).sole).to have_attributes(status: "skipped", skip_reason: "email_not_configured")
    end
  end
end
