# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

# The W-2GU notice's delivery record (M4-5): Resend's signed delivery and
# bounce events, the demo recipient fence, and a demo company's copy.
RSpec.describe "Employee tax form notices", type: :request do
  include PdfBoxText

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:secret_key) { SecureRandom.random_bytes(24) }
  let(:secret) { "whsec_#{Base64.strict_encode64(secret_key)}" }

  def document_for(person)
    EmployeeDocument.create!(company_id: person.company_id, employee: person, tax_year: 2026, revision: 1,
      storage_key: "employee_documents/test/#{person.id}.pdf", sha256: "a" * 64, posted_at: Time.current)
  end

  def notice_for(person, message_id: "re_msg_1", **attributes)
    document = document_for(person)
    EmployeeDocumentNotice.create!(company_id: person.company_id, employee: person, employee_document: document,
      kind: "w2gu_available", status: "sent", sent_at: Time.current, provider_message_id: message_id, **attributes)
  end

  describe "POST /api/v1/integrations/email_events" do
    around do |example|
      previous = ENV["RESEND_WEBHOOK_SECRET"]
      ENV["RESEND_WEBHOOK_SECRET"] = secret
      example.run
    ensure
      ENV["RESEND_WEBHOOK_SECRET"] = previous
    end

    # The shape Resend sends (https://resend.com/docs/dashboard/webhooks/event-types),
    # recipient addresses included.
    def resend_payload(type, email_id:, created_at:, bounce: nil)
      {
        type: type, created_at: created_at,
        data: {
          broadcast_id: nil, created_at: "2027-01-31T09:59:58.123Z", email_id: email_id,
          from: "Cornerstone Payroll <notices@cornerstone.example>", to: [ "worker.own@example.net" ],
          cc: [ "copy.person@example.net" ], bcc: [ "hidden.person@example.net" ], reply_to: [ "help.desk@example.net" ],
          subject: "IMPORTANT TAX RETURN DOCUMENT AVAILABLE", tags: { category: "employee_tax_form_notice" }, bounce: bounce
        }.compact
      }
    end

    def deliver_event(type, email_id: "re_msg_1", bounce: nil, timestamp: Time.current.to_i, key: secret_key, id: "msg_#{SecureRandom.hex(4)}",
      created_at: "2027-01-31T10:00:00.000Z")
      body = resend_payload(type, email_id: email_id, created_at: created_at, bounce: bounce).to_json
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}"))
      post "/api/v1/integrations/email_events", params: body,
        headers: { "CONTENT_TYPE" => "application/json", "svix-id" => id, "svix-timestamp" => timestamp.to_s,
                   "svix-signature" => "v1,#{Base64.strict_encode64('x' * 32)} v1,#{signature}" }
    end

    def reload_notice(notice)
      TenantScope.as_system(reason: "Spec reads the notice") { notice.reload }
    end

    it "records a bounce, keeps it over a later delivery, and audits it without the address" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee, recipient_email: "worker.own@example.net") }

      deliver_event("email.delivery_delayed")
      expect(response).to have_http_status(:no_content)
      expect(reload_notice(notice).delivery_status).to eq("delayed")

      deliver_event("email.bounced", bounce: { type: "Permanent", subType: "General", message: "Mailbox does not exist" })
      expect(response).to have_http_status(:no_content)
      expect(reload_notice(notice)).to have_attributes(delivery_status: "bounced", bounce_type: "Permanent",
        delivery_event_at: Time.zone.parse("2027-01-31T10:00:00Z"))

      deliver_event("email.delivered")
      expect(reload_notice(notice).delivery_status).to eq("bounced")
      expect(notice.paper_due_on).to be_nil

      audit = TenantScope.as_system(reason: "Spec reads audits") { AuditLog.where(action: "employee_tax_forms#notice_bounced").sole }
      expect(audit).to have_attributes(company_id: company.id, record_id: notice.id, event_category: "employee_portal")
      expect(audit.to_json).not_to include("worker.own@example.net")
    end

    it "opens one paper follow-up and dispatches a staff alert when a hard bounce is reconciled" do
      consent = nil
      notice = TenantScope.as_system(reason: "Spec fixture") do
        company.client_operating_profiles.create!(
          effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
          employee_portal_enabled: true, options: { employee_portal: { features: { tax_forms: true } } }
        )
        activate_employee_app!(company)
        user = create(:user, company: company, role: :portal_employee)
        link = EmployeeAccountLink.create!(user: user, company: company, employee: employee,
          status: "active", activated_at: 2.days.ago)
        disclosure = DeliveryDisclosure.create!(kind: "w2gu", version: "test", title: "Test disclosure",
          text: "Test disclosure text", status: "approved", published_at: 3.days.ago)
        consent = DeliveryConsent.create!(company: company, employee: employee, user: user, employee_account_link: link,
          delivery_disclosure: disclosure, kind: "w2gu", disclosure_version: disclosure.version,
          disclosure_digest: disclosure.digest, given_at: 1.day.ago, access_proof_verified_at: 1.day.ago,
          method: "employee_portal_pdf_verified")
        PortalNotificationRecipient.create!(company: company, email: "staff@example.test")
        opted_out = create(:user, company: company, role: "admin")
        list_portal_recipient!(company, user: opted_out)
        PortalNotificationPreference.create!(user: opted_out, category: "tax_form_paper_copies", delivery_mode: "off")
        create(:user, :with_client_assignment, company: company, role: "client", client_access_level: "viewer")
        notice_for(employee, message_id: nil)
      end
      allow(PortalNotifications).to receive(:delivery_enabled?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:deliver).and_return({ "id" => "test-staff-alert" })

      deliver_event("email.bounced", bounce: { type: "Transient" })
      deliver_event("email.bounced", bounce: { type: "Permanent" }, id: "msg_paper", created_at: Time.current.iso8601)
      expect(response).to have_http_status(:no_content)
      expect(reload_notice(notice).paper_due_on).to be_nil
      TenantScope.as_system(reason: "Spec: the notice records its provider ID") do
        notice.update_columns(provider_message_id: "re_msg_1")
      end

      DispatchEmployeeTaxFormNoticesJob.perform_now
      deliver_event("email.bounced", bounce: { type: "Permanent" }, id: "msg_paper", created_at: Time.current.iso8601)
      expect(reload_notice(notice)).to have_attributes(
        paper_bounced_on: PayrollBusinessClock.today, paper_due_on: PayrollBusinessClock.today + 30)
      TenantScope.as_system(reason: "Spec checks consent and staff alert") do
        expect(consent.reload).to be_active
        event = PortalNotificationEvent.where(event_type: "tax_form_paper_required").sole
        expect(event.deliveries.pluck(:status, :delivery_mode, :skip_reason)).to contain_exactly(
          [ "pending", "immediate", nil ], [ "skipped", "immediate", "preference_off" ])
        PortalNotifications::Dispatcher.run!(now: 3.minutes.from_now)
      end
      expect(PortalNotifications::Transport).to have_received(:deliver).with(
        hash_including(subject: "Paper W-2 due — #{company.name} (2026)",
          to: "staff@example.test", text: include("/companies/#{company.id}/year-end?year=2026")), idempotency_key: anything).once
    end

    it "records delivery, and ignores events for other email" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee) }
      deliver_event("email.delivered", email_id: "re_someone_else")
      expect(response).to have_http_status(:no_content)
      expect(reload_notice(notice).delivery_status).to eq("unknown")

      deliver_event("email.opened")
      expect(response).to have_http_status(:no_content)
      deliver_event("email.delivered")
      expect(reload_notice(notice).delivery_status).to eq("delivered")
    end

    it "refuses a wrong signature, an old timestamp and a body that isn't an event" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee) }

      deliver_event("email.bounced", key: SecureRandom.random_bytes(24))
      expect(response).to have_http_status(:unauthorized)
      deliver_event("email.bounced", timestamp: 10.minutes.ago.to_i)
      expect(response).to have_http_status(:unauthorized)
      expect(reload_notice(notice).delivery_status).to eq("unknown")

      post "/api/v1/integrations/email_events", params: "[]", headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "logs none of the payload, and the global filter hides recipient addresses" do
      TenantScope.as_system(reason: "Spec fixture") { notice_for(employee) }
      logged = []
      io = StringIO.new
      previous_logger = ActionController::Base.logger
      ActionController::Base.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :debug }
      ActiveSupport::Notifications.subscribed(->(event) { logged << event.payload[:params] }, "start_processing.action_controller") do
        deliver_event("email.bounced", bounce: { type: "Permanent", subType: "General", message: "worker.own@example.net does not exist" })
      end
      expect(response).to have_http_status(:no_content)
      expect(logged.sole).to include("type" => "[FILTERED]", "data" => "[FILTERED]")
      expect(io.string).to include("EmailEventsController#create")
      [ logged.to_json, io.string ].each do |output|
        expect(output).not_to include("@example.net", "@cornerstone.example", "IMPORTANT TAX")
      end

      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(resend_payload("email.bounced", email_id: "re_msg_1", created_at: "2027-01-31T10:00:00Z").deep_stringify_keys)
      expect(filtered.to_json).not_to include("@example.net", "@cornerstone.example")
      expect(filtered.dig("data", "subject")).to eq("IMPORTANT TAX RETURN DOCUMENT AVAILABLE")
      # A bare from/to is a date range elsewhere and stays readable.
      expect(filter.filter("from" => "2026-01-01", "to" => "2026-12-31", "cc" => "a@example.net"))
        .to eq("from" => "2026-01-01", "to" => "2026-12-31", "cc" => "[FILTERED]")
    ensure
      ActionController::Base.logger = previous_logger
    end

    it "keeps an event that arrives before its notice has the provider id, and the sweep applies it" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee, message_id: nil) }

      deliver_event("email.bounced", email_id: "re_fast", bounce: { type: "Permanent" }, id: "msg_fast_bounce")
      expect(response).to have_http_status(:no_content)
      stored = EmailProviderEvent.sole
      expect(stored).to have_attributes(event_id: "msg_fast_bounce", provider_message_id: "re_fast", delivery_status: "bounced",
        bounce_type: "Permanent", applied_at: nil)
      expect(stored.attributes.values.join(" ")).not_to include("@example.net")
      expect(reload_notice(notice).delivery_status).to eq("unknown")

      TenantScope.as_system(reason: "Spec: the send commits") { notice.update_columns(provider_message_id: "re_fast") }
      DispatchEmployeeTaxFormNoticesJob.perform_now
      expect(reload_notice(notice)).to have_attributes(delivery_status: "bounced", bounce_type: "Permanent")
      expect(stored.reload.applied_at).to be_present
      expect(TenantScope.as_system(reason: "Spec reads audits") { AuditLog.where(action: "employee_tax_forms#notice_bounced").count }).to eq(1)
    end

    it "stores each event once, so a replay changes nothing" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee) }
      2.times do
        deliver_event("email.bounced", bounce: { type: "Permanent" }, id: "msg_replayed")
        expect(response).to have_http_status(:no_content)
      end
      expect(EmailProviderEvent.where(event_id: "msg_replayed").count).to eq(1)
      expect(reload_notice(notice).delivery_status).to eq("bounced")
      expect(TenantScope.as_system(reason: "Spec reads audits") { AuditLog.where(action: "employee_tax_forms#notice_bounced").count }).to eq(1)
    end

    it "never lets an older event overwrite a newer one, and applies stored events oldest first" do
      notice = TenantScope.as_system(reason: "Spec fixture") { notice_for(employee) }
      deliver_event("email.delivery_delayed", created_at: "2027-01-31T10:05:00Z")
      deliver_event("email.delivered", created_at: "2027-01-31T10:00:00Z")
      expect(reload_notice(notice)).to have_attributes(delivery_status: "delayed", delivery_event_at: Time.zone.parse("2027-01-31T10:05:00Z"))

      # Arriving newest first before the notice has its id, they still apply in order.
      later = TenantScope.as_system(reason: "Spec fixture") { notice_for(create(:employee, company: company, department: employee.department), message_id: nil) }
      deliver_event("email.delivered", email_id: "re_later", created_at: "2027-01-31T10:05:00Z")
      deliver_event("email.delivery_delayed", email_id: "re_later", created_at: "2027-01-31T10:00:00Z")
      TenantScope.as_system(reason: "Spec: the send commits") { later.update_columns(provider_message_id: "re_later") }
      EmployeeDocuments::NoticeDeliveryEvent.reconcile!("re_later")
      expect(reload_notice(later)).to have_attributes(delivery_status: "delivered", delivery_event_at: Time.zone.parse("2027-01-31T10:05:00Z"))
      expect(EmailProviderEvent.where(provider_message_id: "re_later").pluck(:applied_at)).to all(be_present)
    end

    it "is a 404 until the signing secret is configured" do
      ENV["RESEND_WEBHOOK_SECRET"] = nil
      deliver_event("email.bounced")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a demo company's notice" do
    let(:demo) { create_demo_company(organization: organization) }
    let(:demo_employee) do
      create(:employee, company: demo, department: create(:department, company: demo), email: "demo.worker@example.test",
        email_verified_at: 1.day.ago)
    end

    around do |example|
      previous = ENV.to_h.slice("PORTAL_EMAIL_NOTIFICATIONS_ENABLED", "PORTAL_EMAIL_TRANSPORT", DemoOutbound::ENV_KEY)
      ENV["PORTAL_EMAIL_NOTIFICATIONS_ENABLED"] = "true"
      ENV["PORTAL_EMAIL_TRANSPORT"] = "capture"
      PortalNotifications::Transport.clear_captured!
      example.run
    ensure
      [ "PORTAL_EMAIL_NOTIFICATIONS_ENABLED", "PORTAL_EMAIL_TRANSPORT", DemoOutbound::ENV_KEY ].each { |key| ENV[key] = previous[key] }
      PortalNotifications::Transport.clear_captured!
    end

    def deliver_demo_notice
      TenantScope.with_company(demo.id) do
        document = document_for(demo_employee)
        notice = EmployeeDocumentNotice.create!(company_id: demo.id, employee: demo_employee, employee_document: document,
          kind: "w2gu_available")
        EmployeeDocuments::TaxFormNotice.send!(notice, document)
        notice.reload
      end
    end

    it "drops a recipient that isn't on the allow-list and sends to one that is" do
      # The transport also rechecks the demo's employee app right before
      # sending (M4-9d); open it to exercise the allow-list itself.
      allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)
      ENV[DemoOutbound::ENV_KEY] = "someone.else@example.net"
      expect(deliver_demo_notice).to have_attributes(status: "skipped", skip_reason: "recipient_not_allowed")
      expect(PortalNotifications::Transport.captured).to be_empty

      ENV[DemoOutbound::ENV_KEY] = "Demo.Worker@example.test"
      TenantScope.with_company(demo.id) { EmployeeDocumentNotice.delete_all && EmployeeDocument.delete_all }
      expect(deliver_demo_notice).to have_attributes(status: "sent")
      expect(PortalNotifications::Transport.captured.sole).to include(to: [ "demo.worker@example.test" ],
        subject: "[Demo] IMPORTANT TAX RETURN DOCUMENT AVAILABLE")
    end

    it "never reaches sending through the job, because the employee app stays off for a demo" do
      ENV[DemoOutbound::ENV_KEY] = "demo.worker@example.test"
      reason = TenantScope.with_company(demo.id) { EmployeeDocuments::TaxFormNotice.skip_reason(document_for(demo_employee)) }
      expect(reason).to eq("feature_off")
    end

    it "prints a final copy with no practice or draft stamp" do
      period = create_committed_demo_pay_period(company: demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
      expect(period).to be_committed
      report = TenantScope.with_company(demo.id) { W2GuAggregator.new(demo, 2026).generate }
      bytes = TenantScope.with_company(demo.id) do
        W2GuOfficialCopies.new(company: demo, report: report, kind: "employee", draft: false, practice: demo.practice_copy?,
          employee_id: demo_employee.id).generate
      end
      text = PDF::Reader.new(StringIO.new(bytes)).pages.flat_map { |page| pdf_rows(page) }.join("\n")
      expect(text).to include(demo_employee.last_name, "W-2GU")
      expect(text).not_to match(/DRAFT|practice|test only|test workspace/i)
      expect(demo.practice_copy?).to be(false)
    end
  end
end
