# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoOutbound, :portal_notifications do
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization, name: "Live Client") }
  let(:demo) { create_demo_company(organization: organization) }
  let(:allowed) { "reviewer+manager@demo-mail.example" }
  let(:other_alias) { "reviewer+outsider@demo-mail.example" }

  around do |example|
    saved = ENV[described_class::ENV_KEY]
    ENV[described_class::ENV_KEY] = " Reviewer+Manager@Demo-Mail.example , reviewer+employee@demo-mail.example,,"
    example.run
  ensure
    ENV[described_class::ENV_KEY] = saved
  end

  describe "the allow-list" do
    it "reads normalized, exact addresses from private configuration and keeps plus aliases distinct" do
      expect(described_class.allowlist).to contain_exactly(allowed, "reviewer+employee@demo-mail.example")
      expect(described_class.allowed?("  REVIEWER+MANAGER@demo-mail.example ")).to be(true)
      expect(described_class.allowed?(other_alias)).to be(false)
      expect(described_class.allowed?("reviewer@demo-mail.example")).to be(false)
      ENV[described_class::ENV_KEY] = nil
      expect(described_class.allowed?(allowed)).to be(false)
    end

    it "never restricts a live company and audits each demo refusal without the address" do
      expect(described_class.permit?(company: live, email: "anyone@client.example", channel: "test")).to be(true)
      expect(described_class.permit?(company: demo, email: allowed, channel: "test")).to be(true)
      expect(Rails.logger).to receive(:info).with(/\[DemoOutbound\] refused channel=test company_id=#{demo.id} domain=elsewhere.example/)
      expect(described_class.permit?(company: demo, email: "someone@elsewhere.example", channel: "test")).to be(false)

      log = AuditLog.find_by!(action: "outbound#recipient_refused", company_id: demo.id)
      expect(log.metadata).to include("channel" => "test", "recipient_domain" => "elsewhere.example")
      expect(log.metadata.to_json).not_to include("someone@")
    end

    it "treats Payroll's contact and shared-inbox normalization as alias-preserving" do
      expect(EmployeeContactValidator.normalize_email(other_alias)).not_to eq(EmployeeContactValidator.normalize_email(allowed))
      expect(PortalNotificationRecipient.normalize_email(other_alias)).to eq(other_alias)
      department = create(:department, company: live)
      create(:employee, company: live, department: department, email: "front+one@kitchen.example")
      create(:employee, company: live, department: department, email: "front+two@kitchen.example")
      admin = create(:user, company: live, organization: organization, role: "admin")
      shared = EmployeeContactHygiene::SharedEmailReport.new(actor: admin, organization_id: organization.id).call
      expect(shared.to_json).not_to include("front+one@kitchen.example")

      create(:employee, company: live, department: department, email: "front+one@kitchen.example")
      shared = EmployeeContactHygiene::SharedEmailReport.new(actor: admin, organization_id: organization.id).call
      expect(shared.to_json).to include("front+one@kitchen.example")
    end
  end

  describe "transports" do
    it "drops non-allowed recipients inside a demo scope and sends nothing when none remain" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent-1" })
      payload = { from: "alerts@example.test", to: [ allowed, other_alias ], subject: "Hello", html: "<p>Hi</p>" }

      described_class.scoped(demo) { StagingMailTransport.deliver(payload) }
      expect(Resend::Emails).to have_received(:send).with(hash_including(to: [ allowed ])).once

      result = described_class.scoped(demo) { StagingMailTransport.deliver(payload.merge(to: other_alias)) }
      expect(result).to include("suppressed" => true)
      expect(Resend::Emails).to have_received(:send).once

      described_class.scoped(live) { StagingMailTransport.deliver(payload.merge(to: other_alias)) }
      expect(Resend::Emails).to have_received(:send).twice
    end

    it "refuses a Clerk invitation for a non-allowed address inside a demo scope" do
      service = ClerkInvitationService.new
      expect(Net::HTTP).not_to receive(:start)
      result = described_class.scoped(demo) { service.create_invitation(email: other_alias) }
      expect(result).to include(success: false, refused: :recipient_not_allowed, error: Company::DEMO_RECIPIENT_REFUSED_MESSAGE)
    end
  end

  describe "logins and invitations" do
    let(:demo_client) { create(:user, company: live, organization: organization, role: "client", email: other_alias).tap { |user| user.update_columns(company_id: demo.id) } }
    let(:staff) { create(:user, company: live, organization: organization, role: "accountant", email: "staff@firm.example") }

    it "identifies demo logins but leaves firm staff working on a demo alone" do
      CompanyAssignment.create!(user: staff, company: demo, workspace_access_level: "operator")
      expect(described_class.demo_company_for(demo_client)).to eq(demo)
      expect(described_class.demo_company_for(staff)).to be_nil
    end

    it "issues no Clerk invitation and sends no invite email to a non-allowed demo login" do
      clerk = instance_double(ClerkInvitationService, configured?: true)
      expect(clerk).not_to receive(:create_invitation)
      demo_client.update_columns(clerk_id: nil, invitation_status: "pending") if demo_client.respond_to?(:invitation_status)
      allow(demo_client).to receive(:awaiting_clerk_binding?).and_return(true)
      allow(User).to receive(:find).and_call_original

      result = PayrollInvitation.new(clerk: clerk).send_invite(demo_client, redirect_url: "https://payroll.example.test/login")
      expect(result).to include(success: false, refused: :recipient_not_allowed)

      allow(Resend::Emails).to receive(:send)
      expect(UserInviteEmailService.send_invite(user: demo_client, invited_by: staff)).to eq(:refused)
      expect(SendUserInviteEmailJob.perform_now(demo_client.id, staff.id)).to eq(:refused)
      expect(Resend::Emails).not_to have_received(:send)
    end

    it "invites an allow-listed demo login normally" do
      demo_client.update_columns(email: allowed)
      clerk = instance_double(ClerkInvitationService, configured?: true)
      allow(demo_client).to receive(:awaiting_clerk_binding?).and_return(true)
      expect(clerk).to receive(:create_invitation).with(hash_including(email: allowed)).and_return(success: false, error: "stop here")
      PayrollInvitation.new(clerk: clerk).send_invite(demo_client.reload.tap { |user| allow(user).to receive(:awaiting_clerk_binding?).and_return(true) },
        redirect_url: "https://payroll.example.test/login")
    end
  end

  describe "portal notifications" do
    let(:thread) { create(:client_portal_thread, company: demo, created_by: create(:user, company: live, organization: organization, role: "client")) }

    it "notifies allow-listed demo recipients only and rechecks before every send" do
      with_portal_email do
        list_portal_recipient!(demo, email: allowed)
        list_portal_recipient!(demo, email: other_alias)
        event = PortalNotifications.record!(event_type: "client_message", company: demo, actor: nil, subject: thread, dedupe_key: "demo-thread-#{thread.id}")
        deliveries = event.deliveries.index_by(&:recipient_email)

        expect(deliveries.fetch(other_alias)).to have_attributes(status: "skipped", skip_reason: "recipient_not_allowed")
        expect(deliveries.fetch(allowed).status).to eq("pending")

        ENV[described_class::ENV_KEY] = "reviewer+employee@demo-mail.example"
        deliveries.fetch(allowed).update_columns(deliver_after: 1.minute.ago)
        PortalNotifications::Dispatcher.run!(now: 1.minute.from_now)
        expect(deliveries.fetch(allowed).reload).to have_attributes(status: "skipped", skip_reason: "recipient_not_allowed")
        expect(captured_portal_emails).to be_empty
      end
    end

    it "still skips practice copies entirely" do
      sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company: live, migration_rehearsal_status: "ready")
      practice_thread = create(:client_portal_thread, company: sandbox, created_by: create(:user, company: live, organization: organization, role: "client"))
      expect(PortalNotifications.record!(event_type: "client_message", company: sandbox, actor: nil, subject: practice_thread,
        dedupe_key: "practice-#{practice_thread.id}")).to be_nil
    end
  end

  describe "employee links" do
    let(:employee) { create(:employee, company: demo, department: create(:department, company: demo), email: other_alias) }

    it "issues no emailed invite token to a non-allowed demo address" do
      link = EmployeeAccountLink.new(company: demo, employee: employee)
      expect { EmployeeLinks::Credentials.issue(link, delivery: "email", email: other_alias) }
        .to raise_error(EmployeeLinks::Error, Company::DEMO_RECIPIENT_REFUSED_MESSAGE)
      expect(link.invite_token_digest).to be_nil
      expect { EmployeeLinks::Credentials.issue(link, delivery: "code") }.not_to raise_error
      expect(EmployeeLinks::Credentials.issue(link, delivery: "email", email: allowed).token).to be_present
    end

    it "sends no invite email to a non-allowed demo address, even from a stale link" do
      link = EmployeeAccountLink.new(company: demo, employee: employee, invite_email: other_alias, invite_token_digest: "a" * 64)
      allow(EmployeeLinks::AppUrl).to receive(:invite_url).and_return("https://harborfinch.example.test/join")
      with_portal_email do
        expect(EmployeeLinks::InviteEmail.deliver(link: link, token: "token", path: "sign_up")).to eq(:skipped)
        expect(captured_portal_emails).to be_empty
      end
    end

    it "binds and claims a demo link only for an allow-listed sign-in address" do
      outsider = create(:user, company: live, organization: organization, role: "client", email: other_alias)
      link = instance_double(EmployeeAccountLink, company: demo, company_id: demo.id, claim_user_id: nil, user_id: nil)
      claim = EmployeeLinks::Claim.allocate
      claim.instance_variable_set(:@user, outsider)
      claim.instance_variable_set(:@azp, nil)
      allow(EmployeeLinks).to receive(:origin_allows_company?).and_return(true)
      allow(demo).to receive(:organization_id).and_return(outsider.organization_id)
      expect(claim.send(:claimable?, link)).to be(false)

      bind_link = instance_double(EmployeeAccountLink, company: demo, company_id: demo.id, invite_open?: true, invite_generation: 1,
        activation_locked?: false, claim_user_id: nil, employee: instance_double(Employee, active?: true), portal_enabled?: true)
      relation = double(find_by: bind_link)
      allow(EmployeeAccountLink).to receive(:lock).and_return(relation)
      metadata = { "payroll_employee_link_id" => 1, "payroll_invite_generation" => 1 }
      expect(EmployeeLinks::Bind.lock_link(outsider, metadata, azp: nil)).to be_nil
      outsider.update_columns(email: allowed)
      expect(EmployeeLinks::Bind.lock_link(outsider.reload, metadata, azp: nil)).to eq(bind_link)
    end
  end

  describe "contact replacement" do
    it "accepts only allow-listed or non-delivering addresses for a demo contact" do
      department = create(:department, company: demo)
      employee = create(:employee, company: demo, department: department, email: nil)
      result = ->(email) { EmployeeContactValidator.new(employee: employee, company: demo, email: email).call }

      expect(result.call("someone@client.example.com").errors[:email]).to include(Company::DEMO_RECIPIENT_REFUSED_MESSAGE)
      expect(result.call(allowed).errors[:email]).to be_blank
      expect(result.call("robin.lantern@harborfinch.example").errors[:email]).to be_blank

      live_employee = create(:employee, company: live, department: create(:department, company: live), email: nil)
      expect(EmployeeContactValidator.new(employee: live_employee, company: live, email: "someone@client.example.com").call.errors[:email]).to be_blank
    end
  end

  describe "the practice access sweep" do
    it "leaves a demo client login alone" do
      demo_client = create(:user, company: live, organization: organization, role: "client", email: allowed)
      demo_client.update_columns(company_id: demo.id)
      ExpirePracticePortalAccessJob.perform_now
      expect(demo_client.reload).to be_active
    end
  end

  describe "payroll reminders" do
    it "sends a demo reminder only to allow-listed recipients" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent" })
      config = PayrollReminderConfig.new(company: demo, recipients: [ allowed, other_alias ])
      outcomes = PayrollReminderService.send(:deliver_to_recipients, config, "Reminder", "<p>Hi</p>", log: nil)
      expect(outcomes.map(&:first)).to eq([ allowed ])
      expect(Resend::Emails).to have_received(:send).once
    end
  end
end
