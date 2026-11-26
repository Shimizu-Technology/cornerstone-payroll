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

  describe "employee app mail while a demo's employee app is off (M4-9d kill switch)" do
    it "refuses every employee channel, even to an allow-listed address, and audits why" do
      DemoOutbound::EMPLOYEE_CHANNELS.each do |channel|
        expect(described_class.permit?(company: demo, email: allowed, channel: channel)).to be(false)
      end
      log = AuditLog.where(action: "outbound#recipient_refused", company_id: demo.id).order(:id).last
      expect(log.metadata).to include("channel" => DemoOutbound::EMPLOYEE_CHANNELS.last, "reason" => "employee_app_off")

      # Client and staff mail keep following the allow-list alone.
      expect(described_class.permit?(company: demo, email: allowed, channel: "portal_notification")).to be(true)
      # A live company is never affected.
      expect(described_class.permit?(company: live, email: "anyone@client.example", channel: "employee_link_invite")).to be(true)

      allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)
      expect(described_class.permit?(company: demo, email: allowed, channel: "employee_link_invite")).to be(true)
      expect(described_class.permit?(company: demo, email: other_alias, channel: "employee_link_invite")).to be(false)
    end
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

    it "rechecks a demo's employee app right before sending employee mail, as the kill switch may have run since enqueue" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent-1" })
      payload = { from: "alerts@example.test", to: [ allowed ], subject: "Your invite", html: "<p>Hi</p>" }
      open = true
      allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?) { open }

      described_class.scoped(demo, channel: "employee_link_invite") { StagingMailTransport.deliver(payload) }
      expect(Resend::Emails).to have_received(:send).once

      open = false
      result = described_class.scoped(demo, channel: "employee_link_invite") { StagingMailTransport.deliver(payload) }
      expect(result).to include("suppressed" => true)
      expect(Resend::Emails).to have_received(:send).once
      expect(AuditLog.where(action: "outbound#recipient_refused", company_id: demo.id).order(:id).last.metadata)
        .to include("channel" => "employee_link_invite", "reason" => "employee_app_off")

      # Other demo mail still follows the allow-list alone.
      described_class.scoped(demo) { StagingMailTransport.deliver(payload) }
      expect(Resend::Emails).to have_received(:send).twice
    end

    it "rechecks employee portal alerts at the transport on the employee channel; staff alerts keep the allow-list alone" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent-1" })
      allow(PortalNotifications::Transport).to receive(:from_email).and_return("alerts@example.test")
      email = instance_double(PortalNotifications::Email,
        payload: { from: "alerts@example.test", to: [ allowed ], subject: "New pay stub", html: "<p>Hi</p>" })
      allow(PortalNotifications::Email).to receive(:new).and_return(email)
      event = Struct.new(:company).new(demo)
      dispatcher = PortalNotifications::Dispatcher.new(Time.current)
      group = ->(audience) { { user: nil, address: allowed, audience: audience, ids: [], key: "key-#{audience}", mode: "instant", events: [ event ] } }

      expect(dispatcher.send(:deliver, group.call("employee"))).to be(false)
      expect(Resend::Emails).not_to have_received(:send)
      expect(AuditLog.where(action: "outbound#recipient_refused", company_id: demo.id).order(:id).last.metadata)
        .to include("channel" => "employee_portal_notification", "reason" => "employee_app_off")

      expect(dispatcher.send(:deliver, group.call("client"))).to be(true)
      expect(Resend::Emails).to have_received(:send).once
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
      CompanyAssignment.create!(user: staff, company: demo)
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

  describe "binding and recovery (fix round)" do
    let(:provider) { instance_double(ClerkInvitationService, configured?: true) }
    let(:admin) { create(:user, company: live, organization: organization, role: "org_admin") }
    let(:nonce) { SecureRandom.hex(32) }
    let(:invitee) do
      create(:user, company: live, organization: organization, role: "client", email: allowed, invitation_status: "pending",
        clerk_invitation_id: "inv_demo", invite_nonce_digest: Digest::SHA256.hexdigest(nonce), invite_nonce_expires_at: 1.day.from_now)
        .tap { |user| user.update_columns(company_id: demo.id) }
    end

    def clerk_user(primary:, verified: true)
      { "id" => "user_demo", "public_metadata" => { "payroll_user_id" => invitee.id, "payroll_invite_nonce" => nonce },
        "primary_email_address_id" => "e1",
        "email_addresses" => [ { "id" => "e1", "email_address" => primary, "verification" => { "status" => verified ? "verified" : "unverified", "strategy" => "ticket" } } ] }
    end

    it "binds a demo client only when the login and the Clerk primary email are both allow-listed" do
      allow(provider).to receive(:invitation_status).with("inv_demo").and_return("accepted")
      allow(provider).to receive(:fetch_user).with("user_demo").and_return(clerk_user(primary: other_alias))
      expect(PayrollInvitation.new(clerk: provider).bind_from_metadata("user_demo", request: nil)).to be_nil
      expect(invitee.reload.clerk_id).to be_nil

      allow(provider).to receive(:fetch_user).with("user_demo").and_return(clerk_user(primary: allowed, verified: false))
      expect(PayrollInvitation.new(clerk: provider).bind_from_metadata("user_demo", request: nil)).to be_nil

      # Demo client logins can't be saved until D5 grants demo access, so the
      # allowed case is checked at the allow-list step itself.
      invitation = PayrollInvitation.new(clerk: provider)
      expect { invitation.send(:refuse_demo_binding!, invitee, [ allowed, allowed ], channel: "test") }.not_to raise_error
      expect { invitation.send(:refuse_demo_binding!, invitee, [ allowed, nil ], channel: "test") }
        .to raise_error(PayrollInvitation::BindingRefused, Company::DEMO_RECIPIENT_REFUSED_MESSAGE)
    end

    it "refuses staff recovery when any address involved is not allow-listed" do
      allow(provider).to receive(:recovery_account).with("user_demo").and_return(
        { id: "user_demo", name: nil, verified_emails: [ allowed, other_alias ], primary_email: other_alias })
      expect { PayrollInvitation.new(clerk: provider).recover!(invitee, "user_demo", confirm_email: allowed, actor: admin, request: nil) }
        .to raise_error(PayrollInvitation::BindingRefused, Company::DEMO_RECIPIENT_REFUSED_MESSAGE)
      expect(invitee.reload.clerk_id).to be_nil
    end

    it "checks the allow-list before closing an earlier invitation" do
      invitee.update_columns(email: other_alias)
      expect(provider).not_to receive(:invitation_status)
      expect(provider).not_to receive(:revoke_invitation)
      result = PayrollInvitation.new(clerk: provider).send_invite(invitee.reload, redirect_url: "https://payroll.example.test/login")
      expect(result).to include(refused: :recipient_not_allowed)
      expect(invitee.reload.clerk_invitation_id).to eq("inv_demo")
    end
  end

  describe "employee sign-up (fix round)" do
    it "answers sign_in and creates no pending login for a non-allowed demo address" do
      employee = create(:employee, company: demo, department: create(:department, company: demo))
      link = instance_double(EmployeeAccountLink, claim_user_id: nil, company: demo, user: nil, employee: employee)
      activation = EmployeeLinks::Activate.allocate
      activation.instance_variable_set(:@email, other_alias)
      expect { expect(activation.send(:prepare, link)).to eq(:sign_in) }.not_to change(User, :count)
    end
  end

  describe "transport details (fix round)" do
    it "filters string and symbol recipient keys together" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent" })
      payload = { from: "alerts@example.test", to: allowed, "to" => other_alias, "cc" => [ other_alias ], subject: "Hi", html: "x" }
      described_class.scoped(demo) { StagingMailTransport.deliver(payload) }
      expect(Resend::Emails).to have_received(:send).with(satisfy { |sent| sent[:to] == [ allowed ] && !sent.key?("to") && !sent.key?(:cc) && !sent.key?("cc") })
    end

    it "keeps an outer demo scope inside a nested non-demo scope" do
      described_class.scoped(demo) do
        described_class.scoped(live) { expect(described_class.scope_company).to eq(demo) }
        described_class.scoped(nil) { expect(described_class.scope_company).to eq(demo) }
      end
      expect(described_class.scope_company).to be_nil
    end

    it "never batches a demo alert with a live client's alert" do
      with_portal_email do
        staff = create(:user, company: live, organization: organization, role: "accountant", email: allowed)
        [ live, demo ].each do |company|
          CompanyAssignment.create!(user: staff, company: company)
          list_portal_recipient!(company, user: staff)
          thread = create(:client_portal_thread, company: company, created_by: create(:user, company: live, organization: organization, role: "client"))
          PortalNotifications.record!(event_type: "client_message", company: company, actor: nil, subject: thread, dedupe_key: "mixed-#{company.id}")
        end
        PortalNotificationDelivery.update_all(deliver_after: 1.minute.ago)
        allow_any_instance_of(ClientPortalThread).to receive(:unread_for?).and_return(true)
        PortalNotifications::Dispatcher.run!(now: 1.minute.from_now)
        keys = PortalNotificationDelivery.where.not(batch_key: nil).group(:company_id).pluck(:company_id, Arel.sql("MIN(batch_key)")).to_h
        expect(keys.keys).to contain_exactly(live.id, demo.id)
        expect(keys.values.uniq.size).to eq(2)
      end
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

    # The allow-list sits behind the demo's employee app switch (M4-9d);
    # open that gate to exercise the allow-list itself.
    before { allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true) }

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
      # The demo's own-subdomain and guarded-process rule has its own spec.
      allow(EmployeeLinks).to receive(:demo_request_allowed?).and_return(true)
      allow(demo).to receive(:organization_id).and_return(outsider.organization_id)
      expect(claim.send(:claimable?, link)).to be(false)

      bind_link = instance_double(EmployeeAccountLink, company: demo, company_id: demo.id, invite_open?: true, invite_generation: 1,
        activation_locked?: false, claim_user_id: nil, employee: instance_double(Employee, active?: true, email: allowed),
        portal_enabled?: true, invite_delivery: "email", invite_email: allowed)
      relation = double(find_by: bind_link)
      allow(EmployeeAccountLink).to receive(:lock).and_return(relation)
      allow(EmployeeLinks::Bind).to receive(:locked_email_on_file).and_return(allowed)
      metadata = { "payroll_employee_link_id" => 1, "payroll_invite_generation" => 1 }
      # A live login never binds a demo link (D5/D6 boundary), allow-listed or not.
      expect(EmployeeLinks::Bind.lock_link(outsider, metadata, azp: nil)).to be_nil
      outsider.update_columns(email: allowed)
      expect(EmployeeLinks::Bind.lock_link(outsider.reload, metadata, azp: nil)).to be_nil
      outsider.update_columns(email: "elsewhere@client.example")

      sign_up = create(:user, company: demo, organization: organization, role: "portal_employee", email: allowed)
      expect(EmployeeLinks::Bind.lock_link(sign_up, metadata, azp: nil)).to eq(bind_link)
      sign_up.update_columns(email: "unlisted@demo-mail.example")
      expect(EmployeeLinks::Bind.lock_link(sign_up.reload, metadata, azp: nil)).to be_nil
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
    it "logs nothing and sends nothing when every demo recipient is refused" do
      allow(Resend::Emails).to receive(:send)
      config = PayrollReminderConfig.new(company: demo, recipients: [ other_alias ])
      period = create(:pay_period, company: demo)
      expect(Rails.logger).not_to receive(:info).with(/\[PayrollReminder\] Sent/)
      expect { PayrollReminderService.send(:send_period_reminder, config, period, "upcoming") }.not_to change(PayrollReminderLog, :count)
      expect(Resend::Emails).not_to have_received(:send)
    end

    it "sends a demo reminder only to allow-listed recipients" do
      allow(Resend::Emails).to receive(:send).and_return({ "id" => "sent" })
      config = PayrollReminderConfig.new(company: demo, recipients: [ allowed, other_alias ])
      outcomes = PayrollReminderService.send(:deliver_to_recipients, config, "Reminder", "<p>Hi</p>", log: nil)
      expect(outcomes.map(&:first)).to eq([ allowed ])
      expect(Resend::Emails).to have_received(:send).once
    end
  end
end
