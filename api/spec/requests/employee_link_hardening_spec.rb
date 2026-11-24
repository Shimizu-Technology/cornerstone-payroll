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

  describe "a retry that changes the sign-up address" do
    let!(:invite) { invite!(employee, actor: staff) }

    before do
      post_activation(activation_params(employee, token: invite.token, email: "first.try@example.net"))
      expect_sign_up_started
    end

    it "keeps the old address while Clerk says the earlier invitation was already accepted" do
      allow(clerk).to receive(:invitation_status).with("inv_1").and_return("accepted")

      post_activation(activation_params(employee, token: invite.token, email: "second.try@example.net"))

      expect(response.parsed_body["next"]).to eq("sign_in")
      expect(invite.link.reload.user).to have_attributes(email: "first.try@example.net", clerk_invitation_id: "inv_1")
      expect(clerk_invitations.size).to eq(1)
    end

    it "keeps the old address when Clerk can't confirm the earlier invitation closed" do
      allow(clerk).to receive(:revoke_invitation).with("inv_1").and_return(success: false, status: 500)

      post_activation(activation_params(employee, token: invite.token, email: "second.try@example.net"))

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

      post_activation(activation_params(employee, token: invite.token, email: "second.try@example.net"))

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
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "first.try@example.net"))

      retry_locks = row_locks { post_activation(activation_params(employee, token: invite.token, email: "second.try@example.net")) }
      # The check locks the link alone; the address is then saved under the
      # login's lock, then the link's.
      expect(retry_locks).to eq(%i[link user link])

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
      expect(claim_locks).to eq(%i[user link])
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
    let!(:invite) { invite!(employee, actor: staff) }

    it "counts no failures against an expired or switched-off invite" do
      invite.link.update_columns(invite_expires_at: 1.minute.ago)
      post_activation(activation_params(employee, token: invite.token, ssn_last4: "0000"))
      expect(response).to have_http_status(:unprocessable_content)

      invite.link.update_columns(invite_expires_at: 1.day.from_now)
      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)
      post_activation(activation_params(employee, token: invite.token, ssn_last4: "0000"))
      expect(response).to have_http_status(:unprocessable_content)

      expect(invite.link.reload.failed_activation_attempts).to eq(0)
      expect(link_audits(invite.link, "activation_failed")).to be_empty
    end

    it "holds generic failures and sign-in answers to a short, bounded minimum time" do
      allow(EmployeeLinks::ResponseFloor).to receive(:enabled?).and_return(true)
      pauses = []
      allow(EmployeeLinks::ResponseFloor).to receive(:pause) { |seconds| pauses << seconds }

      post_activation(activation_params(employee, token: invite.token, ssn_last4: "0000"))
      create(:user, company: company, email: "taken@example.net", role: :client)
      post_activation(activation_params(employee, token: invite.token, email: "taken@example.net"))
      expect(response.parsed_body["next"]).to eq("sign_in")
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      expect_sign_up_started

      expect(pauses.size).to eq(2)
      max = EmployeeLinks::ResponseFloor::MINIMUM + EmployeeLinks::ResponseFloor::JITTER
      expect(pauses).to all(be_between(0, max))
    end
  end
end
