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

        # Privacy: no amounts, employee names, or notes
        combined = [ mail[:subject], mail[:text], mail[:html] ].join("\n")
        expect(combined).not_to include("2,345", "2345", "1,987", "1987", "Jordan", "Reyes", "$")
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
        expect(combined).not_to include("Jordan", "Reyes", "500", "2345", "1987", "bonus", "$")
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
        expect(combined).not_to include("Jordan", "Reyes", "45 hours", "125", "adjust gross", "$")
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
        expect(mail[:subject]).to eq("New activity in Cornerstone Payroll")
        expect(mail[:text]).to include("You have updates waiting in Cornerstone Payroll.")
        expect(mail[:text]).not_to include("Pacific Harbor Grill", "Island Bakery LLC", "Dec 1")
        expect(rows.map { |r| r.reload.status }.uniq).to eq([ "sent" ])
      end
    end

    it "drops revoked clients and reconciles remaining rows under a fresh v2 idempotency key" do
      with_portal_email do
        legacy_key, rows = seed_legacy_two_client_batch!
        CompanyAssignment.where(user: staff_lead, company: second_company).delete_all

        dispatch_at(1.minute.from_now)

        revoked_row = rows.find { |r| r.company_id == second_company.id }.reload
        kept_row = rows.find { |r| r.company_id == company.id }.reload
        expect(revoked_row).to have_attributes(status: "skipped", skip_reason: "access_revoked")
        expect(kept_row.status).to eq("sent")
        expect(kept_row.batch_key).to start_with("portal-notification-v2-")
        expect(kept_row.batch_key).not_to eq(legacy_key)

        expect(captured_portal_emails.size).to eq(1)
        mail = captured_portal_emails.sole
        expect(mail[:idempotency_key]).to eq(kept_row.batch_key)
        expect(mail[:subject]).to include("Pacific Harbor Grill")
        combined = [ mail[:subject], mail[:text], mail[:html] ].join("\n")
        expect(combined).not_to include("Island Bakery LLC", "Dec 1", "Dec 15", "/companies/#{second_company.id}/")
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
end
