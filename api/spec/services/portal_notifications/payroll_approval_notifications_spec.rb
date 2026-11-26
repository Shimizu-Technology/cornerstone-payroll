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
  end
end
