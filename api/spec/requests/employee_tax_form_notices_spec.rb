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

    def deliver_event(type, email_id: "re_msg_1", bounce: nil, timestamp: Time.current.to_i, key: secret_key, id: "msg_#{SecureRandom.hex(4)}")
      body = { type: type, created_at: "2027-01-31T10:00:00.000Z", data: { email_id: email_id, bounce: bounce }.compact }.to_json
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

      audit = TenantScope.as_system(reason: "Spec reads audits") { AuditLog.where(action: "employee_tax_forms#notice_bounced").sole }
      expect(audit).to have_attributes(company_id: company.id, record_id: notice.id, event_category: "employee_portal")
      expect(audit.to_json).not_to include("worker.own@example.net")
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
      ENV[DemoOutbound::ENV_KEY] = "someone.else@example.net"
      expect(deliver_demo_notice).to have_attributes(status: "skipped", skip_reason: "recipient_not_allowed")
      expect(PortalNotifications::Transport.captured).to be_empty

      ENV[DemoOutbound::ENV_KEY] = "Demo.Worker@example.test"
      TenantScope.with_company(demo.id) { EmployeeDocumentNotice.delete_all && EmployeeDocument.delete_all }
      expect(deliver_demo_notice).to have_attributes(status: "sent")
      expect(PortalNotifications::Transport.captured.sole).to include(to: [ "demo.worker@example.test" ],
        subject: "IMPORTANT TAX RETURN DOCUMENT AVAILABLE")
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
