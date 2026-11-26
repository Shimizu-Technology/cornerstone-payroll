# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll approval notifications", :portal_notifications do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization, name: "Cornerstone Practice") }
  let(:company) { create(:company, organization: organization, name: "Pacific Harbor Grill", client_payroll_approval_required: true) }
  let(:second_company) { create(:company, organization: organization, name: "Island Bakery LLC", client_payroll_approval_required: true) }
  let(:staff_lead) { create(:user, company: company, organization: organization, role: "manager", name: "Dana Lead", email: "dana.lead@example.test") }
  let(:staff_backup) { create(:user, company: company, organization: organization, role: "admin", name: "Morgan Backup", email: "morgan.backup@example.test") }
  let(:unlisted_staff) { create(:user, company: company, organization: organization, role: "admin", name: "Unlisted Admin", email: "unlisted@example.test") }
  let(:client_manager) { create(:user, company: company, organization: organization, role: "client", client_access_level: "manager", name: "Casey Manager", email: "casey.manager@example.test") }
  let(:client_viewer) { create(:user, company: company, organization: organization, role: "client", client_access_level: "viewer", name: "Valerie Viewer", email: "valerie.viewer@example.test") }
  let(:employee) { create(:employee, company: company, first_name: "Jordan", last_name: "Reyes") }
  let(:pay_period) do
    create(:pay_period, :calculated, company: company,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
  end
  let!(:payroll_item) do
    create(:payroll_item, company: company, pay_period: pay_period, employee: employee, gross_pay: 2_345.67, net_pay: 1_987.65)
  end

  before do
    ensure_verified_test_tax_years(2026)
    create(:company_assignment, user: staff_lead, company: company)
    create(:company_assignment, user: staff_lead, company: second_company)
    create(:company_assignment, user: client_manager, company: company)
    create(:company_assignment, user: client_viewer, company: company)
    PortalNotificationRecipient.create!(company: company, user: staff_lead, team_role: "lead")
    PortalNotificationRecipient.create!(company: company, user: staff_backup, team_role: "backup")
  end

  def dispatch_at(time)
    travel_to(time) { PortalNotifications::Dispatcher.run! }
  end

  describe "payroll ready for client review (payroll_review_published)" do
    it "emails client managers only with a branded email, period dates, and company-scoped deep link, excluding viewers and sensitive details" do
      with_portal_email do
        PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!

        event = PortalNotificationEvent.find_by!(event_type: "payroll_review_published")
        expect(event.deliveries.pluck(:user_id)).to eq([ client_manager.id ])

        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.size).to eq(1)
        mail = captured_portal_emails.sole
        expect(mail[:to]).to eq("casey.manager@example.test")
        expect(mail[:from]).to eq(%("Cornerstone Payroll" <alerts@example.test>))
        expect(mail[:subject]).to eq("Payroll ready for approval — Pacific Harbor Grill (Nov 1 – Nov 14, 2026)")

        expected_link = "https://payroll.example.test/companies/#{company.id}/pay-runs/#{pay_period.id}/overview"
        expect(mail[:text]).to include(
          "Payroll is ready for your approval",
          "Pacific Harbor Grill",
          "Nov 1 – Nov 14, 2026",
          "Pay date: Nov 20, 2026.",
          "Review payroll: #{expected_link}"
        )
        expect(mail[:html]).to include(
          "Payroll is ready for your approval",
          "Pacific Harbor Grill",
          "Nov 1 – Nov 14, 2026",
          expected_link,
          ">Review payroll</a>",
          "v:roundrect"
        )

        # Privacy: no amounts, employee names, or notes (strip generated URLs so numeric IDs never false-positive)
        combined = [ mail[:subject], mail[:text], mail[:html] ].join("\n")
        combined_without_urls = combined.gsub(%r{https?://\S+}, "")
        expect(combined).not_to include("Jordan", "Reyes", "$")
        expect(combined_without_urls).not_to include("2,345", "2345", "1,987", "1987")
      end
    end

    it "revokes a pending delivery if a client manager is downgraded to a client viewer before dispatch" do
      with_portal_email do
        PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        delivery = PortalNotificationDelivery.find_by!(user: client_manager)
        expect(delivery.status).to eq("pending")

        client_manager.update!(client_access_level: "viewer")
        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails).to be_empty
        expect(delivery.reload).to have_attributes(status: "skipped", skip_reason: "access_revoked")
      end
    end
  end

  describe "client review decisions (payroll_review_decided)" do
    before do
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
    end

    let(:package) { pay_period.payroll_review_packages.current.first! }

    it "emails only the designated account team on client approval, excluding unlisted staff and notes" do
      unlisted_staff
      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager,
          recorded_by: client_manager,
          method: "client_portal",
          revision_id: package.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT,
          notes: "Approved Jordan Reyes bonus of $500"
        )

        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.map { |mail| mail[:to] }).to contain_exactly(
          "dana.lead@example.test",
          "morgan.backup@example.test"
        )
        expect(captured_portal_emails.map { |mail| mail[:to] }).not_to include(unlisted_staff.email)

        expected_link = "https://payroll.example.test/companies/#{company.id}/pay-runs/#{pay_period.id}/work"
        mail = captured_portal_emails.first
        expect(mail[:subject]).to eq("Client approved payroll — Pacific Harbor Grill (Nov 1 – Nov 14, 2026)")
        expect(mail[:html]).to include("Client approved payroll", "Pacific Harbor Grill", "Nov 1 – Nov 14, 2026", expected_link, ">Open pay run</a>")
        expect(mail[:text]).to include("Open pay run: #{expected_link}")

        combined = [ mail[:subject], mail[:text], mail[:html] ].join("\n")
        combined_without_urls = combined.gsub(%r{https?://\S+}, "")
        expect(combined).not_to include("Jordan", "Reyes", "bonus", "$")
        expect(combined_without_urls).not_to include("500", "2345", "1987")
      end
    end

    it "emails only the designated account team when the client requests changes, never including the reason text" do
      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).request_changes!(
          revision_id: package.id,
          note: "Jordan Reyes worked 45 hours, adjust gross by $125"
        )

        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.map { |mail| mail[:to] }).to contain_exactly(
          "dana.lead@example.test",
          "morgan.backup@example.test"
        )

        expected_link = "https://payroll.example.test/companies/#{company.id}/pay-runs/#{pay_period.id}/work"
        mail = captured_portal_emails.first
        expect(mail[:subject]).to eq("Changes requested on payroll — Pacific Harbor Grill (Nov 1 – Nov 14, 2026)")
        expect(mail[:html]).to include("Client requested payroll changes", "Pacific Harbor Grill", "Nov 1 – Nov 14, 2026", expected_link, ">Open pay run</a>")
        expect(mail[:text]).to include("Open pay run: #{expected_link}")

        combined = [ mail[:subject], mail[:text], mail[:html] ].join("\n")
        combined_without_urls = combined.gsub(%r{https?://\S+}, "")
        expect(combined).not_to include("Jordan", "Reyes", "45 hours", "adjust gross", "$")
        expect(combined_without_urls).not_to include("125")
      end
    end
  end

  describe "header sanitization" do
    it "strips unsafe header characters, encoded-words, and HTML from a hostile client name" do
      company.update!(name: %(Evil" <x@y>\r\nBcc: victim@example.test =?UTF-8?B?UGF5?= \u202E<b>Cafe</b>))
      with_portal_email do
        PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        dispatch_at(3.minutes.from_now)

        mail = captured_portal_emails.sole
        [ mail[:from], mail[:subject] ].each do |header|
          expect(header).not_to match(/[\p{Cc}\p{Cf}\u2028\u2029]/)
          expect(header).not_to include("=?")
        end
        expect(Mail::Address.new(mail[:from]).address).to eq("alerts@example.test")
        expect(mail[:html]).not_to include("<b>Cafe</b>")
        expect(mail[:html]).to include("&lt;b&gt;Cafe&lt;/b&gt;")
      end
    end
  end

  describe "per-client digest separation" do
    it "never merges digest alerts from two clients into one email for a staff member covering both" do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationPreference.create!(user: staff_lead, category: "payroll_submissions", delivery_mode: "digest")
      PortalNotificationPreference.create!(user: staff_backup, category: "payroll_submissions", delivery_mode: "off")

      second_client = create(:user, company: second_company, organization: organization, role: "client", client_access_level: "manager")
      create(:company_assignment, user: second_client, company: second_company)
      second_employee = create(:employee, company: second_company)
      second_period = create(:pay_period, :calculated, company: second_company,
        start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      create(:payroll_item, company: second_company, pay_period: second_period, employee: second_employee, gross_pay: 900, net_pay: 800)

      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!

      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
            approver: client_manager, recorded_by: client_manager, method: "client_portal",
            revision_id: pay_period.payroll_review_packages.current.first!.id,
            acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
          )
          PayrollReview::RevisionService.new(pay_period: second_period, actor: second_client).request_changes!(
            revision_id: second_period.payroll_review_packages.current.first!.id,
            note: "Check overtime"
          )
        end

        dispatch_at(Time.utc(2026, 12, 1, 21, 5))

        expect(captured_portal_emails.size).to eq(2)
        first_mail = captured_portal_emails.find { |mail| mail[:subject].include?("Pacific Harbor Grill") }
        second_mail = captured_portal_emails.find { |mail| mail[:subject].include?("Island Bakery LLC") }
        expect(first_mail).to be_present
        expect(second_mail).to be_present

        expect(first_mail[:text]).to include("/companies/#{company.id}/pay-runs/#{pay_period.id}/work")
        expect(first_mail[:text]).not_to include("Island Bakery LLC", "/companies/#{second_company.id}/")

        expect(second_mail[:text]).to include("/companies/#{second_company.id}/pay-runs/#{second_period.id}/work")
        expect(second_mail[:text]).not_to include("Pacific Harbor Grill", "/companies/#{company.id}/")
      end
    end
  end

  describe "DemoOutbound filtering for demo companies" do
    around do |example|
      previous = ENV.fetch(DemoOutbound::ENV_KEY, nil)
      ENV[DemoOutbound::ENV_KEY] = "allowed.manager@demo-mail.example,allowed.staff@demo-mail.example"
      example.run
    ensure
      ENV[DemoOutbound::ENV_KEY] = previous
    end

    it "filters demo payroll-review emails through DemoOutbound and marks the subject [Demo]" do
      demo = create_demo_company(organization: organization, name: "Harbor Finch Demo", fixture_key: "demo-payroll-notify")
      demo.update!(client_payroll_approval_required: true)
      allowed_manager = create(:user, company: demo, organization: organization, role: "client", client_access_level: "manager",
        email: "allowed.manager@demo-mail.example")
      # Simulate a demo client login whose address was later removed from DEMO_EMAIL_ALLOWLIST.
      ENV[DemoOutbound::ENV_KEY] = "allowed.manager@demo-mail.example,allowed.staff@demo-mail.example,blocked.manager@outside.example"
      blocked_manager = create(:user, company: demo, organization: organization, role: "client", client_access_level: "manager",
        email: "blocked.manager@outside.example")
      ENV[DemoOutbound::ENV_KEY] = "allowed.manager@demo-mail.example,allowed.staff@demo-mail.example"
      allowed_staff = create(:user, company: company, organization: organization, role: "admin", email: "allowed.staff@demo-mail.example")
      blocked_staff = create(:user, company: company, organization: organization, role: "admin", email: "blocked.staff@outside.example")
      create(:company_assignment, user: allowed_manager, company: demo)
      create(:company_assignment, user: blocked_manager, company: demo)
      PortalNotificationRecipient.create!(company: demo, user: allowed_staff, team_role: "lead")
      PortalNotificationRecipient.create!(company: demo, user: blocked_staff, team_role: "backup")

      demo_employee = create(:employee, company: demo)
      demo_period = create(:pay_period, :calculated, company: demo,
        start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      create(:payroll_item, company: demo, pay_period: demo_period, employee: demo_employee, gross_pay: 1_000, net_pay: 850)

      with_portal_email do
        PayPeriodLifecycleService.new(pay_period: demo_period, actor: staff_lead).approve!
        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.flat_map { |mail| Array(mail[:to]) }).to eq([ "allowed.manager@demo-mail.example" ])
        expect(captured_portal_emails.sole[:subject]).to start_with("[Demo] Payroll ready for approval — Harbor Finch Demo")
        expect(captured_portal_emails.sole[:text]).to include("Demo company. Not a real payroll record.")
        expect(PortalNotificationDelivery.where(user: blocked_manager, status: %w[pending sent])).to be_empty

        PortalNotifications::Transport.clear_captured!
        PayrollReview::RevisionService.new(pay_period: demo_period, actor: allowed_manager).approve!(
          approver: allowed_manager, recorded_by: allowed_manager, method: "client_portal",
          revision_id: demo_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        dispatch_at(6.minutes.from_now)

        expect(captured_portal_emails.flat_map { |mail| Array(mail[:to]) }).to eq([ "allowed.staff@demo-mail.example" ])
        expect(captured_portal_emails.sole[:subject]).to start_with("[Demo] Client approved payroll — Harbor Finch Demo")
        expect(PortalNotificationDelivery.find_by!(user: blocked_staff)).to have_attributes(
          status: "skipped", skip_reason: "recipient_not_allowed"
        )
        expect(AuditLog.where(company_id: demo.id, action: "outbound#recipient_refused")).to exist
      end
    end

    it "still emails an allow-listed demo recipient when a blocked demo recipient has alerts Off" do
      demo = create_demo_company(organization: organization, name: "Harbor Finch Demo", fixture_key: "demo-off-blocked")
      demo.update!(client_payroll_approval_required: true)
      allowed_manager = create(:user, company: demo, organization: organization, role: "client", client_access_level: "manager",
        email: "allowed.manager@demo-mail.example")
      allowed_staff = create(:user, company: company, organization: organization, role: "admin", email: "allowed.staff@demo-mail.example")
      blocked_staff = create(:user, company: company, organization: organization, role: "admin", email: "blocked.off@outside.example")
      create(:company_assignment, user: allowed_manager, company: demo)
      PortalNotificationRecipient.create!(company: demo, user: allowed_staff, team_role: "lead")
      PortalNotificationRecipient.create!(company: demo, user: blocked_staff, team_role: "backup")
      PortalNotificationPreference.create!(user: blocked_staff, category: "payroll_submissions", delivery_mode: "off")

      demo_employee = create(:employee, company: demo)
      demo_period = create(:pay_period, :calculated, company: demo,
        start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
      create(:payroll_item, company: demo, pay_period: demo_period, employee: demo_employee, gross_pay: 1_000, net_pay: 850)
      PayPeriodLifecycleService.new(pay_period: demo_period, actor: staff_lead).approve!

      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: demo_period, actor: allowed_manager).approve!(
          approver: allowed_manager, recorded_by: allowed_manager, method: "client_portal",
          revision_id: demo_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.flat_map { |mail| Array(mail[:to]) }).to eq([ "allowed.staff@demo-mail.example" ])
        expect(PortalNotificationDelivery.find_by!(user: blocked_staff)).to have_attributes(
          status: "skipped", skip_reason: "recipient_not_allowed", delivery_mode: "immediate"
        )
      end
    end
  end

  describe "saved extra addresses backed by Payroll accounts" do
    before do
      PortalNotificationRecipient.where(company: company).delete_all
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
    end

    let(:package) { pay_period.payroll_review_packages.current.first! }

    def decide_review!
      PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
        approver: client_manager, recorded_by: client_manager, method: "client_portal",
        revision_id: package.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )
    end

    it "drops at enqueue and revokes at dispatch an extra address whose owner becomes a client viewer" do
      PortalNotificationRecipient.create!(company: company, email: "later.viewer@example.test")
      with_portal_email do
        decide_review!
        delivery = PortalNotificationDelivery.find_by!(recipient_email: "later.viewer@example.test")
        expect(delivery.status).to eq("pending")

        viewer = create(:user, company: company, organization: organization, role: "client", client_access_level: "viewer",
          email: "later.viewer@example.test")
        create(:company_assignment, user: viewer, company: company)

        dispatch_at(3.minutes.from_now)
        expect(captured_portal_emails).to be_empty
        expect(delivery.reload).to have_attributes(status: "skipped", skip_reason: "access_revoked")

        # Enqueue path also drops the extra address once it belongs to a viewer.
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).unapprove!
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).approve!
        new_pkg = pay_period.payroll_review_packages.current.first!
        PayrollReview::RevisionService.new(pay_period: pay_period.reload, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: new_pkg.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        new_event = PortalNotificationEvent.find_by!(dedupe_key: "payroll_review_decided:#{new_pkg.id}")
        expect(new_event.recipient_status).to eq("no_recipients")
        expect(new_event.deliveries.sole).to have_attributes(status: "skipped", skip_reason: "no_recipients")
      end
    end

    it "drops at enqueue and revokes at dispatch an extra address whose owner loses company access" do
      PortalNotificationRecipient.create!(company: company, email: "lost.access@example.test")
      with_portal_email do
        decide_review!
        delivery = PortalNotificationDelivery.find_by!(recipient_email: "lost.access@example.test")

        former_staff = create(:user, company: second_company, organization: organization, role: "manager",
          email: "lost.access@example.test")
        create(:company_assignment, user: former_staff, company: second_company)

        dispatch_at(3.minutes.from_now)
        expect(captured_portal_emails).to be_empty
        expect(delivery.reload).to have_attributes(status: "skipped", skip_reason: "access_revoked")

        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).unapprove!
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).approve!
        new_pkg = pay_period.payroll_review_packages.current.first!
        PayrollReview::RevisionService.new(pay_period: pay_period.reload, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: new_pkg.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        new_event = PortalNotificationEvent.find_by!(dedupe_key: "payroll_review_decided:#{new_pkg.id}")
        expect(new_event.recipient_status).to eq("no_recipients")
      end
    end

    it "drops at enqueue and revokes at dispatch an extra address whose owner is deactivated" do
      PortalNotificationRecipient.create!(company: company, email: "former.staff@example.test")
      with_portal_email do
        decide_review!
        delivery = PortalNotificationDelivery.find_by!(recipient_email: "former.staff@example.test")

        create(:user, company: company, organization: organization, role: "admin", active: false,
          email: "former.staff@example.test")

        dispatch_at(3.minutes.from_now)
        expect(captured_portal_emails).to be_empty
        expect(delivery.reload).to have_attributes(status: "skipped", skip_reason: "access_revoked")

        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).unapprove!
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).approve!
        new_pkg = pay_period.payroll_review_packages.current.first!
        PayrollReview::RevisionService.new(pay_period: pay_period.reload, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: new_pkg.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        new_event = PortalNotificationEvent.find_by!(dedupe_key: "payroll_review_decided:#{new_pkg.id}")
        expect(new_event.recipient_status).to eq("no_recipients")
      end
    end
  end

  describe "legacy cross-company batch retry reconciliation" do
    before do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationRecipient.where(company: company, user: staff_backup).delete_all
    end

    def seed_legacy_two_client_batch!
      second_client = create(:user, company: second_company, organization: organization, role: "client", client_access_level: "manager")
      create(:company_assignment, user: second_client, company: second_company)
      second_employee = create(:employee, company: second_company)
      second_period = create(:pay_period, :calculated, company: second_company,
        start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 15), pay_date: Date.new(2026, 12, 20))
      create(:payroll_item, company: second_company, pay_period: second_period, employee: second_employee, gross_pay: 900, net_pay: 800)

      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!

      PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
        approver: client_manager, recorded_by: client_manager, method: "client_portal",
        revision_id: pay_period.payroll_review_packages.current.first!.id,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )
      PayrollReview::RevisionService.new(pay_period: second_period, actor: second_client).approve!(
        approver: second_client, recorded_by: second_client, method: "client_portal",
        revision_id: second_period.payroll_review_packages.current.first!.id,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      )

      legacy_key = "portal-notification-legacybatch123456"
      rows = PortalNotificationDelivery.where(user: staff_lead).joins(:portal_notification_event)
        .where(portal_notification_events: { event_type: "payroll_review_decided" })
      rows.update_all(batch_key: legacy_key, attempts: 1, delivery_mode: "digest", deliver_after: 10.minutes.ago, next_attempt_at: 1.minute.ago)
      [ legacy_key, rows.order(:id).to_a ]
    end

    it "uses the legacy renderer and old idempotency key when every row in a legacy batch is still authorized" do
      with_portal_email do
        legacy_key, rows = seed_legacy_two_client_batch!

        dispatch_at(1.minute.from_now)

        expect(captured_portal_emails.size).to eq(1)
        mail = captured_portal_emails.sole
        expect(mail[:idempotency_key]).to eq(legacy_key)
        expected_text = [
          "You have updates waiting in Cornerstone Payroll.",
          "Sign in to view it.",
          "",
          "Open portal: https://payroll.example.test/pay-periods",
          "",
          PortalNotifications::Email::FOOTER_LINE
        ].join("\n")
        expected_html = <<~HTML
          <!doctype html>
          <html>
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>New activity in Cornerstone Payroll</title></head>
            <body style="margin:0;padding:0;background-color:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#f3f4f6;">
                <tr><td align="center" style="padding:40px 16px;">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:500px;background-color:#ffffff;border:1px solid #e5e7eb;border-radius:12px;">
                    <tr><td style="padding:32px 32px 0 32px;font-size:18px;font-weight:700;color:#111827;">Cornerstone Payroll</td></tr>
                    <tr><td style="padding:16px 32px 0 32px;font-size:15px;line-height:1.6;color:#374151;">You have updates waiting in Cornerstone Payroll.<br>Sign in to view it.</td></tr>
                    <tr><td style="padding:24px 32px 0 32px;">
                      <a href="https://payroll.example.test/pay-periods" style="display:inline-block;padding:12px 28px;background-color:#2563eb;border-radius:6px;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;">Open portal</a>
                    </td></tr>
                    <tr><td style="padding:24px 32px 32px 32px;font-size:12px;line-height:1.6;color:#6b7280;">#{PortalNotifications::Email::FOOTER_LINE}</td></tr>
                  </table>
                </td></tr>
              </table>
            </body>
          </html>
        HTML
        expect(mail.slice(:from, :to, :subject, :text, :html, :reply_to)).to eq(
          from: "alerts@example.test",
          to: staff_lead.email,
          subject: "New activity in Cornerstone Payroll",
          text: expected_text,
          html: expected_html
        )
        expect(mail[:reply_to]).to be_nil
        expect(rows.map { |r| r.reload.status }.uniq).to eq([ "sent" ])
      end
    end

    it "preserves the historical extra-address footer under the original key even if an eligible account registers before retry" do
      PortalNotificationRecipient.where(company: company).delete_all
      PortalNotificationRecipient.create!(company: company, email: "legacy.extra@example.test")
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!

      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        row = PortalNotificationDelivery.find_by!(recipient_email: "legacy.extra@example.test")
        legacy_key = "portal-notification-legacyextra789"
        row.update_columns(batch_key: legacy_key, attempts: 1, delivery_mode: "immediate", deliver_after: 10.minutes.ago, next_attempt_at: 1.minute.ago)

        # Register an eligible staff account with that email before the legacy retry.
        registered_staff = create(:user, company: company, organization: organization, role: "admin", email: "legacy.extra@example.test")
        create(:company_assignment, user: registered_staff, company: company)

        dispatch_at(1.minute.from_now)

        expect(captured_portal_emails.size).to eq(1)
        mail = captured_portal_emails.sole
        expect(mail[:idempotency_key]).to eq(legacy_key)
        expected_text = [
          "You have a new message or update in the portal.",
          "Sign in to view it.",
          "",
          "Open portal: https://payroll.example.test/pay-periods",
          "",
          PortalNotifications::Email::EXTRA_ADDRESS_FOOTER_LINE
        ].join("\n")
        expected_html = <<~HTML
          <!doctype html>
          <html>
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>New activity in Cornerstone Payroll</title></head>
            <body style="margin:0;padding:0;background-color:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#f3f4f6;">
                <tr><td align="center" style="padding:40px 16px;">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:500px;background-color:#ffffff;border:1px solid #e5e7eb;border-radius:12px;">
                    <tr><td style="padding:32px 32px 0 32px;font-size:18px;font-weight:700;color:#111827;">Cornerstone Payroll</td></tr>
                    <tr><td style="padding:16px 32px 0 32px;font-size:15px;line-height:1.6;color:#374151;">You have a new message or update in the portal.<br>Sign in to view it.</td></tr>
                    <tr><td style="padding:24px 32px 0 32px;">
                      <a href="https://payroll.example.test/pay-periods" style="display:inline-block;padding:12px 28px;background-color:#2563eb;border-radius:6px;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;">Open portal</a>
                    </td></tr>
                    <tr><td style="padding:24px 32px 32px 32px;font-size:12px;line-height:1.6;color:#6b7280;">#{PortalNotifications::Email::EXTRA_ADDRESS_FOOTER_LINE}</td></tr>
                  </table>
                </td></tr>
              </table>
            </body>
          </html>
        HTML
        expect(mail.slice(:from, :to, :subject, :text, :html, :reply_to)).to eq(
          from: "alerts@example.test",
          to: "legacy.extra@example.test",
          subject: "New activity in Cornerstone Payroll",
          text: expected_text,
          html: expected_html
        )
        expect(mail[:reply_to]).to be_nil
      end
    end

    it "does not resend a duplicate when a sibling row in a legacy batch was already accepted (sent) or is still in backoff" do
      with_portal_email do
        _legacy_key, rows = seed_legacy_two_client_batch!
        first_row, second_row = rows

        # Case 1: sibling is still in backoff — wait without splitting or sending.
        first_row.update_columns(next_attempt_at: 10.minutes.from_now)
        dispatch_at(1.minute.from_now)
        expect(captured_portal_emails).to be_empty
        expect(second_row.reload).to have_attributes(status: "pending", batch_key: first_row.batch_key)

        # Case 2: sibling was already accepted by provider — mark pending sibling sent, send 0 emails.
        first_row.update_columns(status: "sent", sent_at: 2.minutes.ago, provider_message_id: "resend-accepted-1", completed_at: 2.minutes.ago, next_attempt_at: nil)
        dispatch_at(1.minute.from_now)
        expect(captured_portal_emails).to be_empty
        expect(second_row.reload).to have_attributes(status: "sent", provider_message_id: "resend-accepted-1", batch_key: first_row.batch_key)
      end
    end

    it "marks surviving rows skipped (access_revoked) instead of re-keying when authorization changes after an attempted legacy batch" do
      with_portal_email do
        legacy_key, rows = seed_legacy_two_client_batch!
        CompanyAssignment.where(user: staff_lead, company: second_company).delete_all

        dispatch_at(1.minute.from_now)

        revoked_row = rows.find { |r| r.company_id == second_company.id }.reload
        kept_row = rows.find { |r| r.company_id == company.id }.reload
        expect(revoked_row).to have_attributes(status: "skipped", skip_reason: "access_revoked")
        expect(kept_row).to have_attributes(status: "skipped", skip_reason: "access_revoked", batch_key: legacy_key)
        expect(captured_portal_emails).to be_empty
      end
    end

    it "resends the persisted v2 payload verbatim on retry after a timeout even if company name or pay date changes" do
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        attempts = []
        allow(PortalNotifications::Transport).to receive(:deliver) do |payload, idempotency_key:|
          attempts << { payload: payload.dup, idempotency_key: idempotency_key }
          raise Timeout::Error if attempts.size == 1

          { "id" => "provider-deduped-v2" }
        end

        dispatch_at(3.minutes.from_now)
        expect(attempts.size).to eq(1)

        # Mutate company name and pay_date before retry — retry must still send exact persisted payload.
        company.update!(name: "Renamed Harbor Bistro")
        pay_period.update_columns(pay_date: Date.new(2026, 11, 25))

        dispatch_at(10.minutes.from_now)
        expect(attempts.size).to eq(2)
        expect(attempts.last).to eq(attempts.first)
        expect(attempts.last[:payload][:subject]).to include("Pacific Harbor Grill")
        expect(attempts.last[:payload][:subject]).not_to include("Renamed Harbor Bistro")
      end
    end

    it "never re-keys or duplicates a v2 branded digest batch if one period is revoked after a timed-out attempt" do
      PortalNotificationPreference.create!(user: client_manager, category: "payroll_updates", delivery_mode: "digest")
      second_period = create(:pay_period, :calculated, company: company,
        start_date: Date.new(2026, 11, 15), end_date: Date.new(2026, 11, 28), pay_date: Date.new(2026, 12, 4))
      create(:payroll_item, company: company, pay_period: second_period, employee: employee, gross_pay: 1_500, net_pay: 1_200)

      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
          PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!
        end

        attempts = []
        allow(PortalNotifications::Transport).to receive(:deliver) do |payload, idempotency_key:|
          attempts << { payload: payload.dup, idempotency_key: idempotency_key }
          raise Timeout::Error
        end

        dispatch_at(Time.utc(2026, 12, 1, 21, 5))
        expect(attempts.size).to eq(1)
        original_key = attempts.sole[:idempotency_key]

        # Withdraw second_period before retry: must NOT mint a fresh key and resend.
        PayPeriodLifecycleService.new(pay_period: second_period.reload, actor: staff_lead).unapprove!
        allow(PortalNotifications::Transport).to receive(:deliver).and_call_original

        dispatch_at(Time.utc(2026, 12, 1, 21, 10))
        expect(captured_portal_emails).to be_empty
        rows = PortalNotificationDelivery.where(user: client_manager).order(:id).to_a
        expect(rows.map(&:batch_key).uniq).to eq([ original_key ])
        expect(rows.map(&:status).uniq).to eq([ "skipped" ])
        expect(rows.map(&:skip_reason)).to contain_exactly("resource_unavailable", "access_revoked")
      end
    end
  end

  describe "skipping stale payroll_review_published alerts before send" do
    it "skips the published email if the client approves within the 2-minute batch window" do
      with_portal_email do
        PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        pub_delivery = PortalNotificationDelivery.joins(:portal_notification_event)
          .find_by!(user: client_manager, portal_notification_events: { event_type: "payroll_review_published" })
        expect(pub_delivery.status).to eq("pending")

        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        dispatch_at(3.minutes.from_now)

        expect(pub_delivery.reload).to have_attributes(status: "skipped", skip_reason: "resource_unavailable")
        expect(captured_portal_emails.map { |m| m[:to] }).not_to include(client_manager.email)
      end
    end

    it "skips a queued published digest email if staff withdraw the review before digest time" do
      PortalNotificationPreference.create!(user: client_manager, category: "payroll_updates", delivery_mode: "digest")
      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        end
        pub_delivery = PortalNotificationDelivery.joins(:portal_notification_event)
          .find_by!(user: client_manager, portal_notification_events: { event_type: "payroll_review_published" })
        expect(pub_delivery).to have_attributes(status: "pending", delivery_mode: "digest")

        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).unapprove!

        dispatch_at(Time.utc(2026, 12, 1, 21, 5))

        expect(pub_delivery.reload).to have_attributes(status: "skipped", skip_reason: "resource_unavailable")
        expect(captured_portal_emails).to be_empty
      end
    end
  end

  describe "email-enabled but unconfigured transport" do
    it "skips at enqueue and reports notification_queued false when sender and API key are missing" do
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      package = pay_period.payroll_review_packages.current.first!

      with_portal_email(transport: nil, from: nil) do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: package.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        expect(PayrollReview::PackagePresenter.decision_notification_queued?(package.reload)).to be(false)
        deliveries = PortalNotificationDelivery.joins(:portal_notification_event)
          .where(portal_notification_events: { dedupe_key: "payroll_review_decided:#{package.id}" })
        expect(deliveries.pluck(:status, :skip_reason).uniq).to eq([ [ "skipped", "email_not_configured" ] ])

        dispatch_at(3.minutes.from_now)
        expect(Resend::Emails).not_to have_received(:send)
      end
    end
  end

  describe "preference changes retime queued alerts" do
    it "retimes unattempted queued deliveries when switching Immediate <-> Digest and rechecks at dispatch" do
      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        end
        delivery = PortalNotificationDelivery.find_by!(user: client_manager)
        expect(delivery).to have_attributes(delivery_mode: "immediate", deliver_after: Time.utc(2026, 12, 1, 20, 32))

        # Switch Immediate -> Digest via Preferences.update!
        PortalNotifications::Preferences.update!(client_manager, { "payroll_updates" => "digest" })
        expect(delivery.reload).to have_attributes(delivery_mode: "digest", deliver_after: Time.utc(2026, 12, 1, 21, 0))

        dispatch_at(Time.utc(2026, 12, 1, 20, 35))
        expect(captured_portal_emails).to be_empty

        # Switch Digest -> Immediate via Preferences.update!
        PortalNotifications::Preferences.update!(client_manager, { "payroll_updates" => "immediate" })
        expect(delivery.reload).to have_attributes(delivery_mode: "immediate", deliver_after: Time.utc(2026, 12, 1, 20, 32))

        # Simulate a direct preference update to digest right before dispatch: dispatcher rechecks and defers.
        PortalNotificationPreference.find_by!(user: client_manager, category: "payroll_updates").update!(delivery_mode: "digest")
        dispatch_at(Time.utc(2026, 12, 1, 20, 35))
        expect(captured_portal_emails).to be_empty
        expect(delivery.reload).to have_attributes(status: "pending", delivery_mode: "digest", deliver_after: Time.utc(2026, 12, 1, 21, 0))

        dispatch_at(Time.utc(2026, 12, 1, 21, 5))
        expect(captured_portal_emails.size).to eq(1)
        expect(delivery.reload.status).to eq("sent")
      end
    end
  end

  describe "two-company digest separation on a shared destination" do
    it "separates digest emails by company even when events share the same destination group" do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationRecipient.where(company: company, user: staff_backup).delete_all
      PortalNotificationPreference.create!(user: staff_lead, category: "client_messages", delivery_mode: "digest")

      second_client = create(:user, company: second_company, organization: organization, role: "client")
      create(:company_assignment, user: second_client, company: second_company)

      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          thread_a = create(:client_portal_thread, company: company, created_by: client_manager)
          msg_a = create(:client_portal_message, company: company, client_portal_thread: thread_a, author: client_manager)
          PortalNotifications.message_created!(msg_a)

          thread_b = create(:client_portal_thread, company: second_company, created_by: second_client)
          msg_b = create(:client_portal_message, company: second_company, client_portal_thread: thread_b, author: second_client)
          PortalNotifications.message_created!(msg_b)
        end

        dispatch_at(Time.utc(2026, 12, 1, 21, 5))

        expect(captured_portal_emails.size).to eq(2)
        expect(captured_portal_emails.map { |m| m[:idempotency_key] }.uniq.size).to eq(2)
        expect(PortalNotificationDelivery.where(user: staff_lead).pluck(:company_id, :status)).to contain_exactly(
          [ company.id, "sent" ],
          [ second_company.id, "sent" ]
        )
      end
    end
  end

  describe "mid-dispatch revocation per group" do
    it "rechecks authorization immediately before rendering the next group and drops a client revoked mid-dispatch" do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationRecipient.where(company: company, user: staff_backup).delete_all

      second_client = create(:user, company: second_company, organization: organization, role: "client", client_access_level: "manager")
      create(:company_assignment, user: second_client, company: second_company)
      second_employee = create(:employee, company: second_company)
      second_period = create(:pay_period, :calculated, company: second_company,
        start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 15), pay_date: Date.new(2026, 12, 20))
      create(:payroll_item, company: second_company, pay_period: second_period, employee: second_employee, gross_pay: 900, net_pay: 800)

      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!

      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        PayrollReview::RevisionService.new(pay_period: second_period, actor: second_client).approve!(
          approver: second_client, recorded_by: second_client, method: "client_portal",
          revision_id: second_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        # While the first group's email is sending, revoke staff_lead's access to the other company.
        delivered = []
        allow(PortalNotifications::Transport).to receive(:deliver).and_wrap_original do |original, payload, **kwargs|
          delivered << payload
          if delivered.size == 1
            other_company_id = payload[:subject].include?("Pacific Harbor Grill") ? second_company.id : company.id
            CompanyAssignment.where(user: staff_lead, company_id: other_company_id).delete_all
          end
          original.call(payload, **kwargs)
        end

        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.size).to eq(1)
        sent_subject = captured_portal_emails.sole[:subject]
        revoked_company = sent_subject.include?("Pacific Harbor Grill") ? second_company : company
        revoked_row = PortalNotificationDelivery.where(user: staff_lead, company_id: revoked_company.id)
          .joins(:portal_notification_event)
          .find_by!(portal_notification_events: { event_type: "payroll_review_decided" })
        expect(revoked_row).to have_attributes(status: "skipped", skip_reason: "access_revoked")
        expect(sent_subject).not_to include(revoked_company.name)
      end
    end

    it "skips with destination_changed instead of sending to either address if a user's email changes mid-dispatch" do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationRecipient.where(company: company, user: staff_backup).delete_all

      second_client = create(:user, company: second_company, organization: organization, role: "client", client_access_level: "manager")
      create(:company_assignment, user: second_client, company: second_company)
      second_employee = create(:employee, company: second_company)
      second_period = create(:pay_period, :calculated, company: second_company,
        start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 15), pay_date: Date.new(2026, 12, 20))
      create(:payroll_item, company: second_company, pay_period: second_period, employee: second_employee, gross_pay: 900, net_pay: 800)

      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!

      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        PayrollReview::RevisionService.new(pay_period: second_period, actor: second_client).approve!(
          approver: second_client, recorded_by: second_client, method: "client_portal",
          revision_id: second_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        # While the first group's email is sending, change staff_lead's email address.
        delivered = []
        allow(PortalNotifications::Transport).to receive(:deliver).and_wrap_original do |original, payload, **kwargs|
          delivered << payload
          staff_lead.update!(email: "dana.new.mailbox@example.test") if delivered.size == 1
          original.call(payload, **kwargs)
        end

        dispatch_at(3.minutes.from_now)

        expect(captured_portal_emails.size).to eq(1)
        expect(captured_portal_emails.map { |m| m[:to] }).to eq([ "dana.lead@example.test" ])
        skipped_row = PortalNotificationDelivery.where(user: staff_lead, status: "skipped").sole
        expect(skipped_row.skip_reason).to eq("destination_changed")
      end
    end

    it "does not overwrite another worker's active claim on a sibling row" do
      PortalNotificationRecipient.create!(company: second_company, user: staff_lead, team_role: "lead")
      PortalNotificationRecipient.where(company: company, user: staff_backup).delete_all

      second_client = create(:user, company: second_company, organization: organization, role: "client", client_access_level: "manager")
      create(:company_assignment, user: second_client, company: second_company)
      second_employee = create(:employee, company: second_company)
      second_period = create(:pay_period, :calculated, company: second_company,
        start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 15), pay_date: Date.new(2026, 12, 20))
      create(:payroll_item, company: second_company, pay_period: second_period, employee: second_employee, gross_pay: 900, net_pay: 800)

      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
      PayPeriodLifecycleService.new(pay_period: second_period, actor: staff_lead).approve!

      with_portal_email do
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        PayrollReview::RevisionService.new(pay_period: second_period, actor: second_client).approve!(
          approver: second_client, recorded_by: second_client, method: "client_portal",
          revision_id: second_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        rows = PortalNotificationDelivery.where(user: staff_lead).joins(:portal_notification_event)
          .where(portal_notification_events: { event_type: "payroll_review_decided" }).order(:id).to_a
        first_row, second_row = rows
        batch_key = "portal-notification-v2-siblingclaim"
        active_claim_time = 2.minutes.ago.change(usec: 0)
        first_row.update_columns(batch_key: batch_key, attempts: 1, deliver_after: 10.minutes.ago, claimed_at: nil, claimed_by: nil)
        second_row.update_columns(batch_key: batch_key, attempts: 1, deliver_after: 10.minutes.ago, claimed_at: active_claim_time, claimed_by: "other-worker-token")

        dispatch_at(Time.current)

        expect(captured_portal_emails).to be_empty
        expect(second_row.reload).to have_attributes(status: "pending", claimed_by: "other-worker-token", claimed_at: active_claim_time)
        expect(first_row.reload).to have_attributes(status: "pending", batch_key: batch_key)
      end
    end
  end

  describe "cross-organization isolation during preference retiming" do
    it "never retimes another organization's unowned extra-address delivery sharing the same mailbox" do
      PortalNotificationRecipient.where(company: company).delete_all
      PortalNotificationRecipient.create!(company: company, email: "shared.mailbox@gmail.com")
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!

      foreign_org = create(:organization, name: "Other Firm")
      foreign_company = create(:company, organization: foreign_org, name: "Foreign Client")
      foreign_staff = create(:user, company: foreign_company, organization: foreign_org, role: "admin",
        email: "sharedmailbox+work@googlemail.com")
      create(:company_assignment, user: foreign_staff, company: foreign_company)

      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          thread = create(:client_portal_thread, company: company, created_by: client_manager)
          msg = create(:client_portal_message, company: company, client_portal_thread: thread, author: client_manager)
          PortalNotifications.message_created!(msg)
        end

        # Simulate a pending extra-email row in org A (e.g., enqueued before foreign user existed).
        org_a_delivery = PortalNotificationDelivery.find_by!(company: company, recipient_email: "shared.mailbox@gmail.com")
        org_a_delivery.update_columns(status: "pending", skip_reason: nil, completed_at: nil,
          delivery_mode: "immediate", deliver_after: Time.utc(2026, 12, 1, 20, 32))

        PortalNotifications::Preferences.update!(foreign_staff, { "client_messages" => "digest" })

        expect(org_a_delivery.reload).to have_attributes(
          delivery_mode: "immediate",
          deliver_after: Time.utc(2026, 12, 1, 20, 32)
        )
      end
    end
  end

  describe "Gmail and Googlemail mailbox alias matching" do
    before do
      PortalNotificationRecipient.where(company: company).delete_all
      PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
    end

    it "applies account eligibility to dotted, plus-tagged, and googlemail variants at both enqueue and dispatch without inventing rules for other domains" do
      PortalNotificationRecipient.create!(company: company, email: "dot.viewer@gmail.com")
      PortalNotificationRecipient.create!(company: company, email: "plusviewer+alerts@gmail.com")
      PortalNotificationRecipient.create!(company: company, email: "g.mail.viewer+payroll@googlemail.com")
      PortalNotificationRecipient.create!(company: company, email: "alex+outside@otherdomain.test")

      with_portal_email do
        # Enqueue while no account exists yet: all 4 extras queue pending.
        PayrollReview::RevisionService.new(pay_period: pay_period, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: pay_period.payroll_review_packages.current.first!.id,
          acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )

        # Register ineligible client viewers at the canonical Gmail addresses and at alex@otherdomain.test.
        %w[dotviewer@gmail.com plusviewer@gmail.com gmailviewer@gmail.com alex@otherdomain.test].each do |email|
          viewer = create(:user, company: company, organization: organization, role: "client", client_access_level: "viewer", email: email)
          create(:company_assignment, user: viewer, company: company)
        end

        # Dispatch revokes all 3 Gmail/Googlemail aliases, while keeping the distinct non-Gmail address.
        dispatch_at(3.minutes.from_now)
        expect(captured_portal_emails.map { |m| m[:to] }).to eq([ "alex+outside@otherdomain.test" ])
        %w[dot.viewer@gmail.com plusviewer+alerts@gmail.com g.mail.viewer+payroll@googlemail.com].each do |alias_email|
          row = PortalNotificationDelivery.find_by!(recipient_email: alias_email)
          expect(row).to have_attributes(status: "skipped", skip_reason: "access_revoked")
        end

        # Enqueue path also drops all 3 Gmail/Googlemail aliases.
        PortalNotifications::Transport.clear_captured!
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).unapprove!
        PayPeriodLifecycleService.new(pay_period: pay_period.reload, actor: staff_lead).approve!
        new_pkg = pay_period.payroll_review_packages.current.first!
        PayrollReview::RevisionService.new(pay_period: pay_period.reload, actor: client_manager).approve!(
          approver: client_manager, recorded_by: client_manager, method: "client_portal",
          revision_id: new_pkg.id, acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
        )
        new_event = PortalNotificationEvent.find_by!(dedupe_key: "payroll_review_decided:#{new_pkg.id}")
        expect(new_event.deliveries.pluck(:recipient_email)).to eq([ "alex+outside@otherdomain.test" ])
      end
    end
  end

  describe "conditional preference retiming under concurrent claim" do
    it "does not overwrite a delivery that was claimed concurrently during preference retiming" do
      with_portal_email do
        travel_to(Time.utc(2026, 12, 1, 20, 30)) do
          PayPeriodLifecycleService.new(pay_period: pay_period, actor: staff_lead).approve!
        end
        delivery = PortalNotificationDelivery.find_by!(user: client_manager)
        original_deliver_after = delivery.deliver_after

        # Simulate a concurrent dispatcher claim occurring right after the row is read for retiming.
        allow(PortalNotifications).to receive(:deliver_after_for).and_wrap_original do |original, mode, occurred_at|
          PortalNotificationDelivery.where(id: delivery.id).update_all(
            attempts: 1,
            claimed_at: Time.current,
            batch_key: "portal-notification-v2-concurrent-claim"
          )
          original.call(mode, occurred_at)
        end

        PortalNotifications::Preferences.update!(client_manager, { "payroll_updates" => "digest" })

        expect(delivery.reload).to have_attributes(
          delivery_mode: "immediate",
          deliver_after: original_deliver_after,
          attempts: 1,
          batch_key: "portal-notification-v2-concurrent-claim"
        )
      end
    end
  end
end
