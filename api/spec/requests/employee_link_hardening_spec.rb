# frozen_string_literal: true

require "rails_helper"

# M4-2 review fixes: superseded Clerk sign-ups, retries that change the
# address, the bound identity, lock order, credentials read once, and
# answers that don't vary by why they failed.
RSpec.describe "Employee link hardening", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Example Diner") }
  let(:staff) { create(:user, role: :admin, company: company) }
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", email: "riley.own@example.net",
      date_of_birth: Date.new(1990, 4, 12))
  end
  let(:fresh_second_factor) { { fva: [ 0, 0 ], two_factor_enabled: true } }

  before { enable_employee_app!(company) }

  def resend!(link, **options)
    as_staff_in(company) { EmployeeLinks::Resend.call(link: link.reload, actor: staff, **options) }
  end

  def claim(subject, params, path: "/api/v1/employee/links/claim", **token_options)
    post path, params: params.to_json, headers: bearer(subject, **token_options).merge("CONTENT_TYPE" => "application/json")
  end

  # The users and links locked by each statement, in order.
  def row_locks
    locks = []
    capture = lambda do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.include?("FOR UPDATE") || sql.include?("FOR NO KEY UPDATE")

      locks << :user if sql.include?('FROM "users"')
      locks << :link if sql.include?('FROM "employee_account_links"')
      locks << :employee if sql.include?('FROM "employees"')
    end
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { yield }
    locks
  end

  describe "a resend retires Clerk sign-ups started for the earlier invite" do
    it "won't bind the old Clerk invitation, by nonce or by generation" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      expect_sign_up_started
      expect(clerk_invitations.sole.dig(:public_metadata, :payroll_invite_generation)).to eq(1)
      pending_user = invite.link.reload.user

      resend!(invite.link)
      expect(invite.link.reload.invite_generation).to eq(2)
      expect(pending_user.reload).to have_attributes(invite_nonce_digest: nil, invite_nonce_expires_at: nil)
      expect(clerk).to have_received(:revoke_invitation).with("inv_1")

      accept_clerk_invitation!("user_old_ticket")
      get "/api/v1/auth/me", headers: bearer("user_old_ticket")
      expect(response).to have_http_status(:unauthorized)
      expect(pending_user.reload.clerk_id).to be_nil
      expect(invite.link.reload).to be_invited
    end

    it "checks the invite generation at bind even if the nonce still matches" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      accept_clerk_invitation!("user_riley")
      invite.link.update_columns(invite_generation: invite.link.invite_generation + 1)

      get "/api/v1/auth/me", headers: bearer("user_riley")

      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload.user).to have_attributes(clerk_id: nil, invitation_status: "pending")
    end

    it "lets the person sign up again with the resent invite" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      resent = resend!(invite.link)

      post_activation(activation_params(employee, token: resent.token, email: "riley.own@example.net"))
      expect_sign_up_started
      accept_clerk_invitation!("user_riley")
      get "/api/v1/auth/me", headers: bearer("user_riley")

      expect(response).to have_http_status(:ok)
      expect(invite.link.reload).to have_attributes(status: "active")
      expect(invite.link.user).to have_attributes(clerk_id: "user_riley", email: "riley.own@example.net")
    end
  end

  describe "a resend when Clerk already accepted the sign-up" do
    let!(:invite) { invite!(employee, actor: staff) }
    let(:pending_user) { invite.link.reload.user }

    before do
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      expect_sign_up_started
    end

    it "rotates a still-pending sign-up only after Clerk confirms it revoked the invitation" do
      allow(clerk).to receive(:revoke_invitation).with("inv_1").and_return(success: false, status: 503)

      expect { resend!(invite.link) }.to raise_error(EmployeeLinks::Error, EmployeeLinks::Resend::UNCONFIRMED)
      expect(invite.link.reload.invite_generation).to eq(1)
      expect(pending_user.reload.invite_nonce_digest).to be_present

      allow(clerk).to receive(:revoke_invitation).with("inv_1").and_return(success: true)
      resend!(invite.link)
      expect(invite.link.reload.invite_generation).to eq(2)
      expect(pending_user.reload.invite_nonce_digest).to be_nil
    end

    it "keeps an accepted, unbound sign-up bindable and tells staff to have the person sign in" do
      accept_clerk_invitation!("user_riley")
      nonce = pending_user.invite_nonce_digest

      expect { resend!(invite.link) }.to raise_error(EmployeeLinks::SignUpAccepted, EmployeeLinks::Resend::ACCEPTED)
      expect(invite.link.reload).to have_attributes(invite_generation: 1, status: "invited")
      expect(pending_user.reload).to have_attributes(invite_nonce_digest: nonce, clerk_invitation_id: "inv_1")
      expect(link_audits(invite.link, "invite_resent")).to be_empty

      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:ok)
      expect(invite.link.reload).to be_active
      expect(pending_user.reload.clerk_id).to eq("user_riley")
    end

    it "points staff at a reset when the accepted sign-up can no longer finish" do
      accept_clerk_invitation!("user_riley")
      invite.link.update_columns(invite_expires_at: 1.minute.ago)

      expect { resend!(invite.link) }.to raise_error(EmployeeLinks::SignUpAccepted, EmployeeLinks::Resend::ACCEPTED_STALE)
      expect(invite.link.reload.invite_generation).to eq(1)
    end

    describe "staff reset the sign-up" do
      def reset!(link, **options)
        as_staff_in(company) do
          EmployeeLinks::ResetSignUp.call(link: link.reload, actor: staff, reason: "Signed up on a shared phone", **options)
        end
      end

      before do
        accept_clerk_invitation!("user_riley")
        allow(clerk).to receive(:users_with_email).with("riley.own@example.net")
          .and_return([ clerk.fetch_user("user_riley"), { "id" => "user_unrelated", "public_metadata" => {} } ])
      end

      it "removes the unbound Clerk account, clears the login's binding and issues a new generation" do
        reset = reset!(invite.link)

        expect(clerk).to have_received(:revoke_user_sessions).with("user_riley", email: "riley.own@example.net")
        expect(clerk).to have_received(:delete_user).with("user_riley", email: "riley.own@example.net")
        expect(clerk).not_to have_received(:delete_user).with("user_unrelated", anything)
        # Phase 1 moved to generation 2 and the new invite is generation 3.
        expect(invite.link.reload).to have_attributes(invite_generation: 3, status: "invited", user_id: pending_user.id,
          sign_up_reset_requested_at: nil, sign_up_reset_requested_by_id: nil, sign_up_reset_reason: nil)
        expect(pending_user.reload).to have_attributes(clerk_id: nil, clerk_invitation_id: nil, invite_nonce_digest: nil,
          invite_nonce_expires_at: nil, invitation_status: "pending")
        expect(link_audits(invite.link, "sign_up_reset_started").sole.metadata)
          .to include("reason" => "Signed up on a shared phone", "pending_login_id" => pending_user.id)
        audit = link_audits(invite.link, "sign_up_reset").sole
        expect(audit.metadata).to include("reason" => "Signed up on a shared phone", "deleted_clerk_users" => 1,
          "requested_by_id" => staff.id, "requested_reason" => "Signed up on a shared phone")

        # The superseded ticket never binds, by any path.
        get "/api/v1/auth/me", headers: bearer("user_riley")
        expect(response).to have_http_status(:unauthorized)
        post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
        expect(response).to have_http_status(:unprocessable_content)

        post_activation(activation_params(employee, token: reset.token, email: "riley.own@example.net"))
        expect_sign_up_started
        expect(clerk_invitations.last.dig(:public_metadata, :payroll_invite_generation)).to eq(3)
        accept_clerk_invitation!("user_riley_again")
        get "/api/v1/auth/me", headers: bearer("user_riley_again")
        expect(response).to have_http_status(:ok)
        expect(invite.link.reload).to be_active
      end

      it "needs a reason" do
        expect { reset!(invite.link, reason: "  ") }.to raise_error(EmployeeLinks::Error, /reason/)
        expect(clerk).not_to have_received(:delete_user)
      end

      it "refuses when the sign-in bound first, and never touches Clerk" do
        get "/api/v1/auth/me", headers: bearer("user_riley")
        expect(response).to have_http_status(:ok)

        expect { reset!(invite.link) }.to raise_error(EmployeeLinks::Error, "Only an open invite can be reset")
        expect(clerk).not_to have_received(:users_with_email)
        expect(clerk).not_to have_received(:delete_user)
        expect(invite.link.reload).to have_attributes(status: "active", sign_up_reset_requested_at: nil)
        expect(link_audits(invite.link, "sign_up_reset_started")).to be_empty
      end

      it "refuses to bind once phase 1 committed, even while Clerk still has the account" do
        allow(clerk).to receive(:users_with_email).with("riley.own@example.net").and_return(nil)

        expect { reset!(invite.link) }.to raise_error(EmployeeLinks::Error, EmployeeLinks::ResetSignUp::CLERK_FAILED)
        expect(invite.link.reload).to have_attributes(invite_generation: 2, invite_token_digest: nil, invite_code_digest: nil,
          sign_up_reset_requested_by_id: staff.id, sign_up_reset_reason: "Signed up on a shared phone")
        expect(invite.link.sign_up_reset_requested_at).to be_present
        expect(pending_user.reload).to have_attributes(invite_nonce_digest: nil, clerk_invitation_id: "inv_1")

        get "/api/v1/auth/me", headers: bearer("user_riley")
        expect(response).to have_http_status(:unauthorized)
        expect(pending_user.reload.clerk_id).to be_nil
        expect(invite.link.reload).to be_invited
        expect(clerk).not_to have_received(:delete_user)
      end

      it "refuses to bind while the reset is pending, even with a current generation and nonce" do
        invite.link.update_columns(sign_up_reset_requested_at: Time.current, sign_up_reset_reason: "Stuck")

        get "/api/v1/auth/me", headers: bearer("user_riley")
        expect(response).to have_http_status(:unauthorized)
        expect(pending_user.reload.clerk_id).to be_nil
      end

      it "stays pending when Clerk fails partway, and a retry resumes and finishes it" do
        second = { "id" => "user_riley_second", "public_metadata" => clerk.fetch_user("user_riley")["public_metadata"] }
        allow(clerk).to receive(:users_with_email).with("riley.own@example.net")
          .and_return([ clerk.fetch_user("user_riley"), second ])
        allow(clerk).to receive(:delete_user).with("user_riley_second", anything).and_return(success: false, status: 500)

        expect { reset!(invite.link) }.to raise_error(EmployeeLinks::Error, EmployeeLinks::ResetSignUp::CLERK_FAILED)
        expect(clerk).to have_received(:delete_user).with("user_riley", email: "riley.own@example.net")
        expect(invite.link.reload).to have_attributes(invite_generation: 2, status: "invited")
        expect(invite.link).to be_sign_up_reset_pending
        expect(link_audits(invite.link, "sign_up_reset")).to be_empty

        # Nothing restarts the old sign-up while the reset is pending.
        post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
        expect(response).to have_http_status(:unprocessable_content)
        expect { resend!(invite.link) }.to raise_error(EmployeeLinks::Error, EmployeeLinks::Resend::RESET_PENDING)

        allow(clerk).to receive(:users_with_email).with("riley.own@example.net").and_return([ second ])
        allow(clerk).to receive(:delete_user).with("user_riley_second", anything).and_return(success: true)
        reset = reset!(invite.link, reason: "Retrying after a Clerk outage")

        expect(clerk).to have_received(:delete_user).with("user_riley_second", email: "riley.own@example.net").twice
        expect(invite.link.reload).to have_attributes(invite_generation: 3, sign_up_reset_requested_at: nil)
        expect(link_audits(invite.link, "sign_up_reset_started").count).to eq(1)
        expect(link_audits(invite.link, "sign_up_reset_resumed").sole.metadata)
          .to include("reason" => "Retrying after a Clerk outage")
        expect(link_audits(invite.link, "sign_up_reset").sole.metadata)
          .to include("requested_reason" => "Signed up on a shared phone", "reason" => "Retrying after a Clerk outage")

        post_activation(activation_params(employee, token: reset.token, email: "riley.own@example.net"))
        expect_sign_up_started
      end

      it "deletes only Clerk accounts whose metadata names both this login and this link" do
        metadata = clerk.fetch_user("user_riley")["public_metadata"]
        other_link = { "id" => "user_other_link", "public_metadata" => metadata.merge("payroll_employee_link_id" => invite.link.id + 1) }
        other_login = { "id" => "user_other_login", "public_metadata" => metadata.merge("payroll_user_id" => pending_user.id + 1) }
        as_string = { "id" => "user_as_string", "public_metadata" => metadata.merge("payroll_user_id" => pending_user.id.to_s) }
        allow(clerk).to receive(:users_with_email).with("riley.own@example.net")
          .and_return([ other_link, other_login, as_string, { "id" => "user_no_metadata" } ])

        reset!(invite.link)

        expect(clerk).not_to have_received(:revoke_user_sessions)
        expect(clerk).not_to have_received(:delete_user)
        expect(link_audits(invite.link, "sign_up_reset").sole.metadata).to include("deleted_clerk_users" => 0)
      end

      it "never deletes a Clerk account a Payroll login is bound to" do
        create(:user, role: :accountant, company: company, clerk_id: "user_riley")

        reset!(invite.link)
        expect(clerk).not_to have_received(:delete_user)
        expect(invite.link.reload.invite_generation).to eq(3)
      end

      it "checks again right before deleting that no Payroll login is bound to the account" do
        allow(clerk).to receive(:revoke_user_sessions) do
          create(:user, role: :accountant, company: company, clerk_id: "user_riley")
          { success: true, revoked: 1 }
        end

        reset!(invite.link)
        expect(clerk).not_to have_received(:delete_user)
      end
    end
  end

  describe "a retry that changes the sign-up address" do
    # Only a staff-printed code may sign up with an address other than the one on file.
    let!(:invite) { invite!(employee, actor: staff, delivery: "code") }

    before do
      post_activation(activation_params(employee, code: invite.code, email: "first.try@example.net"))
      expect_sign_up_started
    end

    it "keeps the old address while Clerk says the earlier invitation was already accepted" do
      allow(clerk).to receive(:invitation_status).with("inv_1").and_return("accepted")

      post_activation(activation_params(employee, code: invite.code, email: "second.try@example.net"))

      expect(response.parsed_body["next"]).to eq("sign_in")
      expect(invite.link.reload.user).to have_attributes(email: "first.try@example.net", clerk_invitation_id: "inv_1")
      expect(clerk_invitations.size).to eq(1)
    end

    it "keeps the old address when Clerk can't confirm the earlier invitation closed" do
      allow(clerk).to receive(:revoke_invitation).with("inv_1").and_return(success: false, status: 500)

      post_activation(activation_params(employee, code: invite.code, email: "second.try@example.net"))

      expect(response).to have_http_status(:service_unavailable)
      expect(invite.link.reload.user).to have_attributes(email: "first.try@example.net", clerk_invitation_id: "inv_1")
      expect(clerk_invitations.size).to eq(1)
    end

    it "saves the new address only with the replacement invitation, and refuses one taken meanwhile" do
      allow(clerk).to receive(:create_invitation) do |**options|
        clerk_invitations << options
        # Another login takes the address while Clerk makes the invitation.
        create(:user, company: company, role: :client, email: "second.try@example.net") if clerk_invitations.size == 2
        { success: true, invitation_id: "inv_#{clerk_invitations.length}", status: "pending", url: "https://accounts.example.test/x" }
      end

      post_activation(activation_params(employee, code: invite.code, email: "second.try@example.net"))

      expect(response.parsed_body["next"]).to eq("sign_in")
      expect(invite.link.reload.user).to have_attributes(email: "first.try@example.net")
      expect(clerk).to have_received(:revoke_invitation).with("inv_2", email: "second.try@example.net")
    end
  end

  describe "the bound Clerk identity" do
    let!(:invite) { invite!(employee, actor: staff) }

    before { post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net")) }

    it "refuses a Clerk account whose primary address isn't the login's, or isn't verified" do
      accept_clerk_invitation!("user_riley", email: "someone.else@example.net")
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)

      accept_clerk_invitation!("user_riley", status: "unverified")
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload).to be_invited
    end

    it "confirms the contact email only on proof from Clerk, not because an invite went there" do
      code_employee = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", email: nil,
        date_of_birth: Date.new(1988, 1, 2))
      code_invite = invite!(code_employee, actor: staff, delivery: "code")
      post_activation(activation_params(code_employee, code: code_invite.code, email: "avery@example.net"))
      accept_clerk_invitation!("user_avery", strategy: "email_code")
      get "/api/v1/auth/me", headers: bearer("user_avery")
      expect(code_employee.reload).to have_attributes(email: "avery@example.net")
      expect(code_employee.email_verified_at).to be_present

      # The emailed token went to this address, but Clerk reports it unproven.
      accept_clerk_invitation!("user_riley", invitation_index: 0, strategy: "admin")
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:ok)
      expect(employee.reload.email_verified_at).to be_nil
    end
  end

  describe "lock order (EmployeeLinks: employee, logins, links)" do
    it "locks the login before the link when binding, retrying a sign-up, claiming and resending" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "first.try@example.net"))

      retry_locks = row_locks { post_activation(activation_params(employee, code: invite.code, email: "second.try@example.net")) }
      # The check locks the employee, then the link; the address is then saved
      # under the login's lock, then the link's.
      expect(retry_locks).to eq(%i[employee link user link])

      accept_clerk_invitation!("user_riley")
      bind_locks = row_locks { get "/api/v1/auth/me", headers: bearer("user_riley") }
      expect(response).to have_http_status(:ok)
      # (A later lock records the sign-in itself, after the bind committed.)
      expect(bind_locks.first(3)).to eq(%i[user link employee])

      other = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", email: "avery@example.net",
        date_of_birth: Date.new(1988, 1, 2))
      code_invite = invite!(other, actor: staff, delivery: "code")
      post_activation(activation_params(other, code: code_invite.code, email: "abandoned@example.net"))
      resend_locks = row_locks { code_invite = resend!(code_invite.link, delivery: "code") }
      expect(resend_locks.first(3)).to eq(%i[employee user link])

      create(:user, role: :accountant, company: company, name: "Avery Cruz", clerk_id: "user_avery_staff")
      claim_locks = row_locks { claim("user_avery_staff", activation_params(other, code: code_invite.code), **fresh_second_factor) }
      expect(response).to have_http_status(:created)
      # The employee row first, so a contact edit (which locks it too) can't
      # commit between the email-on-file check and the activation.
      expect(claim_locks).to eq(%i[employee user link])
    end

    it "refuses a bind while a contact edit holds the employee row, and binds on the next sign-in" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token))
      accept_clerk_invitation!("user_riley")
      held = true
      allow(EmployeeLinks::Bind).to receive(:locked_email_on_file).and_wrap_original do |original, *args|
        held ? :locked : original.call(*args)
      end

      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload).to be_invited

      held = false
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:ok)
      expect(invite.link.reload).to be_active
    end

    it "takes the company and then the employee row without waiting at bind, and reports either held" do
      link = instance_double(EmployeeAccountLink, company_id: 2, employee_id: 1)
      allow(EmployeeLinks).to receive(:lock_company!).with(2, nowait: true).and_raise(ActiveRecord::LockWaitTimeout)
      expect(EmployeeLinks::Bind.locked_email_on_file(link)).to eq(:locked)

      allow(EmployeeLinks).to receive(:lock_company!).with(2, nowait: true).and_return(2)
      relation = double
      allow(Employee).to receive(:where).and_return(relation)
      allow(relation).to receive(:lock).with("FOR NO KEY UPDATE NOWAIT").and_return(relation)
      allow(relation).to receive(:pick).and_raise(ActiveRecord::LockWaitTimeout)
      expect(EmployeeLinks::Bind.locked_email_on_file(link)).to eq(:locked)
    end

    it "refuses a staff-printed code's bind while the employee row is held, then binds once it's free" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "riley.code@example.net"))
      expect_sign_up_started
      accept_clerk_invitation!("user_riley_code")
      held = true
      allow(EmployeeLinks::Bind).to receive(:locked_email_on_file).and_wrap_original do |original, *args|
        held ? :locked : original.call(*args)
      end

      get "/api/v1/auth/me", headers: bearer("user_riley_code")
      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload).to be_invited

      held = false
      get "/api/v1/auth/me", headers: bearer("user_riley_code")
      expect(response).to have_http_status(:ok)
      expect(invite.link.reload).to be_active
    end

    it "retries a bind that hit a deadlock, re-checking everything under the lock" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      accept_clerk_invitation!("user_riley")
      attempts = 0
      allow_any_instance_of(PayrollInvitation).to receive(:retry_after_deadlock?).and_return(true)
      allow(EmployeeLinks::Bind).to receive(:lock_link).and_wrap_original do |original, *args, **options|
        attempts += 1
        raise ActiveRecord::Deadlocked, "deadlock detected" if attempts == 1

        original.call(*args, **options)
      end

      get "/api/v1/auth/me", headers: bearer("user_riley")

      expect(response).to have_http_status(:ok)
      expect(attempts).to eq(2)
      expect(invite.link.reload).to be_active
      expect(AuditLog.where(action: "authentication#clerk_identity_bound").count).to eq(1)
    end

    it "serializes the company lock-alert count behind an advisory lock" do
      invite = invite!(employee, actor: staff)
      statements = []
      capture = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        5.times { post_activation(activation_params(employee, token: invite.token, ssn_last4: "0000")) }
      end

      advisory = statements.index { |sql| sql.include?("pg_advisory_xact_lock(#{EmployeeLinks::Verify::ALERT_LOCK_NAMESPACE}, #{company.id})") }
      count = statements.rindex { |sql| sql.include?("COUNT(*)") && sql.include?('FROM "audit_logs"') }
      expect(advisory).to be_present
      expect(count).to be > advisory
    end
  end

  describe "a credential read once, from the body" do
    let!(:invite) { invite!(employee, actor: staff, delivery: "code") }

    it "refuses check fields in the query string on sign-up and claim" do
      post "/api/v1/employee/activation?token=other-token", params: activation_params(employee, code: invite.code).to_json,
        headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:bad_request)

      create(:user, role: :accountant, company: company, name: "Riley Santos", clerk_id: "user_staffer")
      claim("user_staffer", activation_params(employee, code: invite.code), path: "/api/v1/employee/links/claim?code=X", **fresh_second_factor)
      expect(response).to have_http_status(:bad_request)
      expect(invite.link.reload).to be_invited
      expect(User.where(role: :portal_employee)).to be_empty
    end

    it "uses the code when the token is overlong or blank, as the throttle does" do
      post_activation(activation_params(employee, code: invite.code, token: "t" * 257, email: "riley.own@example.net"))
      expect_sign_up_started
    end
  end

  describe "answers that don't vary by why they failed" do
    let!(:invite) { invite!(employee, actor: staff, delivery: "code") }

    it "counts no failures against an expired or switched-off invite" do
      invite.link.update_columns(invite_expires_at: 1.minute.ago)
      post_activation(activation_params(employee, code: invite.code, ssn_last4: "0000"))
      expect(response).to have_http_status(:unprocessable_content)

      invite.link.update_columns(invite_expires_at: 1.day.from_now)
      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)
      post_activation(activation_params(employee, code: invite.code, ssn_last4: "0000"))
      expect(response).to have_http_status(:unprocessable_content)

      expect(invite.link.reload.failed_activation_attempts).to eq(0)
      expect(link_audits(invite.link, "activation_failed")).to be_empty
    end

    it "holds generic failures and sign-in answers to a short, bounded minimum time" do
      allow(EmployeeLinks::ResponseFloor).to receive(:enabled?).and_return(true)
      pauses = []
      allow(EmployeeLinks::ResponseFloor).to receive(:pause) { |seconds| pauses << seconds }

      post_activation(activation_params(employee, code: invite.code, ssn_last4: "0000"))
      create(:user, company: company, email: "taken@example.net", role: :client)
      post_activation(activation_params(employee, code: invite.code, email: "taken@example.net"))
      expect(response.parsed_body["next"]).to eq("sign_in")
      post_activation(activation_params(employee, code: invite.code, email: "riley.own@example.net"))
      expect_sign_up_started

      expect(pauses.size).to eq(2)
      max = EmployeeLinks::ResponseFloor::MINIMUM + EmployeeLinks::ResponseFloor::JITTER
      expect(pauses).to all(be_between(0, max))
    end
  end
end
