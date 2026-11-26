# frozen_string_literal: true

require "rails_helper"

# M4-2: invite -> sign-up -> bind -> employee session, and the existing-login
# claim path. Requests run with real token verification and the RLS guard in
# raise mode (every request is strict in spec/support/rls_spec_context.rb).
RSpec.describe "Employee link lifecycle", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Example Diner") }
  let(:staff) { create(:user, role: :admin, company: company) }
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", email: "riley.own@example.net",
      date_of_birth: Date.new(1990, 4, 12))
  end

  before { enable_employee_app!(company) }

  def sign_up_and_bind!(employee, token: nil, code: nil, email: "riley.own@example.net", subject: "user_riley")
    post_activation(activation_params(employee, token: token, code: code, email: email).compact)
    expect_sign_up_started
    accept_clerk_invitation!(subject)
    get "/api/v1/auth/me", headers: bearer(subject)
    expect(response).to have_http_status(:ok)
    User.find_by!(clerk_id: subject)
  end

  describe "new employee sign-up" do
    it "invites by email, signs up, binds in /auth/me and opens an audited employee session" do
      invite = invite!(employee, actor: staff)
      link = invite.link
      expect(invite).to have_attributes(path: "sign_up", code: nil)
      expect(invite.token).to be_present
      expect(link).to have_attributes(status: "invited", user_id: nil, invite_delivery: "email",
        invite_token_digest: EmployeeAccountLink.token_digest(invite.token), invite_email: "riley.own@example.net")
      expect(link.invite_expires_at).to be_within(1.minute).of(14.days.from_now)
      expect(link_audits(link, "invited").sole).to have_attributes(actor_type: "staff_user", user_id: staff.id)

      post_activation(activation_params(employee, token: invite.token, email: "Riley.Own@Example.net "))

      expect_sign_up_started
      expect(response.parsed_body).to eq("next" => "sign_up", "sign_up_url" => "https://accounts.example.test/accept/1", "message" => nil)
      pending_user = link.reload.user
      expect(pending_user).to have_attributes(role: "portal_employee", email: "riley.own@example.net", company_id: company.id,
        invitation_status: "pending", clerk_id: nil, active: true, name: employee.display_name)
      expect(link).to be_invited
      expect(clerk_invitations.sole).to include(email: "riley.own@example.net",
        redirect_url: "#{EmployeeLinkHelpers::APP_URL}/sign-up")
      expect(clerk_invitations.sole.fetch(:public_metadata)).to include(payroll_user_id: pending_user.id,
        payroll_employee_link_id: link.id, role: "portal_employee")

      accept_clerk_invitation!("user_riley")
      get "/api/v1/auth/me", headers: bearer("user_riley")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("roles")).to eq("staff" => false, "client" => false, "employee_links_count" => 1)
      expect(pending_user.reload).to have_attributes(clerk_id: "user_riley", invitation_status: "accepted")
      expect(link.reload).to have_attributes(status: "active", invite_token_digest: nil, invite_code_digest: nil)
      expect(link.activated_at).to be_present
      expect(employee.reload.email_verified_at).to be_present
      expect(link_audits(link, "activated").sole).to have_attributes(actor_type: "employee", user_id: pending_user.id)

      get "/api/v1/employee/links", headers: bearer("user_riley")
      expect(response.parsed_body).to eq("links" => [ { "id" => link.id, "company_name" => "Example Diner",
        "subdomain_slug" => nil, "demo" => false, "status" => "active", "former_access_until" => nil, "latest_pay_date" => nil } ])

      get "/api/v1/employee/context", headers: bearer("user_riley").merge("X-Employee-Link-Id" => link.id.to_s)
      expect(response).to have_http_status(:ok)
      view = AuditLog.where(action: "employee_portal/context#show").order(:id).last
      expect(view).to have_attributes(actor_type: "employee", user_id: pending_user.id, company_id: company.id)

      # The used token can't start anything again.
      post_activation(activation_params(employee, token: invite.token))
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "signs up with a printed one-time code, saves the sign-up email when the record has none, and leaves it unconfirmed" do
      employee.update!(email: nil)
      invite = invite!(employee, actor: staff, delivery: "code")
      expect(invite.token).to be_nil
      expect(invite.code).to match(/\A[ACDEFGHJKMNPQRTUVWXY34679]{10}\z/)
      expect(invite.link.invite_code_digest).to eq(EmployeeAccountLink.code_digest(invite.code))
      expect(invite.link.invite_code_digest).not_to eq(Digest::SHA256.hexdigest(invite.code))

      spaced = invite.code.downcase.scan(/.{5}/).join("-")
      user = sign_up_and_bind!(employee, code: spaced, email: "new.person@example.net")

      expect(user.email).to eq("new.person@example.net")
      expect(employee.reload).to have_attributes(email: "new.person@example.net", contact_source: "employee", email_verified_at: nil)
      expect(invite.link.reload).to have_attributes(status: "active", invite_code_digest: nil)

      post_activation(activation_params(employee, code: invite.code))
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses an emailed invite's sign-up with any address but the one on file, with a clear message" do
      invite = invite!(employee, actor: staff)

      post_activation(activation_params(employee, token: invite.token, email: "other.address@example.net"))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::EMAIL_MISMATCH, "code" => "email_mismatch")
      expect(invite.link.reload).to have_attributes(status: "invited", user_id: nil, failed_activation_attempts: 0)
      expect(clerk_invitations).to be_empty
      expect(link_audits(invite.link, "sign_up_email_refused").sole.metadata).to include("reason" => "email_mismatch")

      # The address on file still works.
      sign_up_and_bind!(employee, token: invite.token)
      expect(invite.link.reload).to be_active
    end

    it "refuses an emailed invite whose address no longer matches the email on file" do
      invite = invite!(employee, actor: staff)
      # Written directly, past the model's email-change handling (which closes the invite).
      employee.update_columns(email: "riley.new@example.net")

      post_activation(activation_params(employee, token: invite.token))
      expect(response.parsed_body).to include("code" => "email_mismatch")
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      expect(response.parsed_body).to include("code" => "email_mismatch")
      expect(clerk_invitations).to be_empty
    end

    it "never binds a sign-up whose address stopped matching the email on file after it started" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token))
      expect_sign_up_started
      accept_clerk_invitation!("user_riley")
      employee.update_columns(email: "riley.new@example.net")

      get "/api/v1/auth/me", headers: bearer("user_riley")

      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload).to be_invited
    end

    it "records at issuance that staff printed a code, and retires a code with no recorded staff issuer" do
      invite = invite!(employee, actor: staff, delivery: "code")
      expect(invite.link.invite_code_issued_by_staff).to be(true)

      [ false, nil ].each do |recorded|
        invite.link.update_columns(invite_code_issued_by_staff: recorded)
        post_activation(activation_params(employee, code: invite.code))

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => EmployeeLinks::CODE_RETIRED, "code" => "code_retired")
      end
      expect(clerk_invitations).to be_empty
    end

    it "decides by the issuer recorded for the code, not the issuer's role today" do
      invite = invite!(employee, actor: staff, delivery: "code")
      staff.update_columns(role: User.roles.fetch("client"))

      post_activation(activation_params(employee, code: invite.code))
      expect_sign_up_started
    end

    it "never binds a code sign-up once the code's staff issuance is gone" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code))
      expect_sign_up_started
      accept_clerk_invitation!("user_riley")
      invite.link.update_columns(invite_code_issued_by_staff: nil)

      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(invite.link.reload).to be_invited
    end

    it "keeps the record's email unless the employee chooses a staff-printed code's sign-up address for notices" do
      invite = invite!(employee, actor: staff, delivery: "code")
      sign_up_and_bind!(employee, code: invite.code, email: "other.address@example.net")
      expect(employee.reload).to have_attributes(email: "riley.own@example.net", email_verified_at: nil)

      second = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", email: "avery@example.net",
        date_of_birth: Date.new(1988, 1, 2))
      invite = invite!(second, actor: staff, delivery: "code")
      post_activation(activation_params(second, code: invite.code, email: "avery.new@example.net", use_for_notices: true))
      accept_clerk_invitation!("user_avery")
      get "/api/v1/auth/me", headers: bearer("user_avery")
      expect(second.reload).to have_attributes(email: "avery.new@example.net", contact_source: "employee", email_verified_at: nil)
    end

    it "reuses the pending login on a retry, updates a changed free email and rotates the Clerk invitation" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "first.try@example.net"))
      pending_user = invite.link.reload.user

      expect do
        post_activation(activation_params(employee, code: invite.code, email: "second.try@example.net"))
      end.not_to change(User, :count)

      expect_sign_up_started
      expect(pending_user.reload.email).to eq("second.try@example.net")
      expect(invite.link.reload.user_id).to eq(pending_user.id)
      expect(clerk_invitations.map { |options| options[:email] }).to eq(%w[first.try@example.net second.try@example.net])
      expect(clerk).to have_received(:revoke_invitation).with("inv_1")
      expect(link_audits(invite.link, "sign_up_started").pluck(Arel.sql("metadata->>'retry'"))).to eq(%w[false true])
    end

    it "gives the same sign-in answer for an address with a login, a placeholder, or one Clerk already has" do
      invite = invite!(employee, actor: staff, delivery: "code")
      create(:user, company: company, email: "taken@example.net", role: :client)
      answers = []

      [ "TAKEN@example.net", "noreply@example.net" ].each do |email|
        post_activation(activation_params(employee, code: invite.code, email: email))
        answers << [ response.status, response.parsed_body ]
      end
      allow(clerk).to receive(:create_invitation).and_return(success: false, error: "That email address is taken.", status_code: 422)
      post_activation(activation_params(employee, code: invite.code, email: "clerk.has.it@example.net"))
      answers << [ response.status, response.parsed_body ]

      expect(answers.uniq).to eq([ [ 200, { "next" => "sign_in", "sign_up_url" => nil,
        "message" => Api::V1::EmployeePortal::ActivationsController::SIGN_IN } ] ])
      expect(answers.first.last.to_s).not_to include("taken@example.net")
    end

    it "never binds a login whose link closed, expired or moved to another company's subdomain before sign-up finished" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token))
      accept_clerk_invitation!("user_riley")
      link = invite.link

      link.update_columns(invite_expires_at: 1.minute.ago)
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["code"]).to eq("payroll_account_unbound")
      expect(link.reload.user).to have_attributes(clerk_id: nil, invitation_status: "pending")

      link.update_columns(invite_expires_at: 1.day.from_now, status: "revoked")
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)

      link.update_columns(status: "invited", activation_locked_until: 1.hour.from_now)
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)

      link.update_columns(activation_locked_until: nil)
      employee.update_columns(status: "terminated")
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)

      employee.update_columns(status: "active")
      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(link.reload).to be_invited
      expect(AuditLog.where(action: "authentication#clerk_identity_bound")).to be_empty
    end
  end

  describe "failures that never reveal whether an employee exists" do
    let!(:invite) { invite!(employee, actor: staff) }
    let(:generic) do
      [ 422, { "error" => Api::V1::EmployeePortal::ActivationsController::FAILED, "code" => "activation_failed" } ]
    end

    def attempt(**overrides)
      post_activation(activation_params(employee, token: invite.token).merge(overrides))
      [ response.status, response.parsed_body ]
    end

    it "answers wrong DOB, wrong SSN-4, unknown token, wrong code, malformed input, expired and revoked links the same way" do
      other = create(:employee, company: company, date_of_birth: Date.new(1970, 1, 1))
      code_invite = invite!(other, actor: staff, delivery: "code")

      answers = [
        attempt(date_of_birth: "1990-04-13"),
        attempt(ssn_last4: "0000"),
        attempt(date_of_birth: "04/12/1990"),
        attempt(token: "not-a-real-token"),
        attempt(token: nil, code: "ACDEFGHJKM"),
        attempt(token: nil, code: code_invite.code, date_of_birth: "1971-01-01"),
        attempt(email: "not-an-email")
      ]
      invite.link.update_columns(invite_expires_at: 1.minute.ago)
      answers << attempt
      invite.link.update_columns(invite_expires_at: 1.day.from_now, status: "revoked")
      answers << attempt
      invite.link.update_columns(status: "invited")
      employee.update_columns(status: "inactive")
      answers << attempt

      expect(answers.uniq).to eq([ generic ])
      expect(User.where(role: :portal_employee)).to be_empty
      expect(clerk_invitations).to be_empty
    end

    it "locks a link after five failures for 24 hours, even for the right details, until staff unlock it" do
      4.times { attempt(ssn_last4: "0000") }
      expect(invite.link.reload).to have_attributes(failed_activation_attempts: 4, activation_locked_until: nil)
      expect(link_audits(invite.link, "activation_failed").count).to eq(4)
      expect(link_audits(invite.link, "activation_failed").first).to have_attributes(actor_type: "system_job", user_id: nil)

      expect(attempt(ssn_last4: "0000")).to eq(generic)
      link = invite.link.reload
      expect(link.activation_locked_until).to be_within(1.minute).of(24.hours.from_now)
      expect(link_audits(link, "activation_locked").count).to eq(1)
      expect(PortalNotificationEvent.where(event_type: "employee_signup_locked", subject: link).count).to eq(1)

      expect(attempt).to eq(generic)
      expect(link.reload.failed_activation_attempts).to eq(5)
      expect(link.user).to be_nil

      as_staff_in(company) { EmployeeLinks::Unlock.call(link: link, actor: staff) }
      expect(link_audits(link, "activation_unlocked").sole.user_id).to eq(staff.id)
      post_activation(activation_params(employee, token: invite.token))
      expect_sign_up_started
    end

    it "clears an expired lock and counts afresh" do
      5.times { attempt(ssn_last4: "0000") }
      travel_to(25.hours.from_now) do
        post_activation(activation_params(employee, token: invite.token))
        expect_sign_up_started
        expect(invite.link.reload.failed_activation_attempts).to eq(0)
      end
    end

    it "alerts staff once when a third link at one company locks within an hour" do
      others = Array.new(3) do |i|
        create(:employee, company: company, email: "worker#{i}@example.net", date_of_birth: Date.new(1980, 1, i + 1))
      end
      invites = others.map { |other| invite!(other, actor: staff) }
      allow(PayrollTelemetry).to receive(:log).and_call_original

      invites.each do |other_invite|
        5.times { post_activation(activation_params(other_invite.link.employee, token: other_invite.token, ssn_last4: "0000")) }
      end
      5.times { attempt(ssn_last4: "0000") }

      alert = AuditLog.where(action: "employee_links#activation_lock_alert").sole
      expect(alert).to have_attributes(company_id: company.id, event_category: "security", actor_type: "system_job")
      # Staff watch error-level events (M4 runbook, Alerts); every lock is logged too.
      expect(PayrollTelemetry).to have_received(:log).with(:error, "employee_links.activation_lock_alert", hash_including(company_id: company.id)).once
      expect(PayrollTelemetry).to have_received(:log).with(:warn, "employee_links.activation_locked", hash_including(company_id: company.id)).exactly(4).times
    end
  end

  describe "claiming with an existing login" do
    let(:client_user) do
      create(:user, role: :client, company: company, email: "riley.own@example.net", name: "Riley Santos", clerk_id: "user_client")
    end
    let(:fresh_second_factor) { { fva: [ 0, 0 ], two_factor_enabled: true } }

    def claim(subject, params, **token_options)
      post "/api/v1/employee/links/claim", params: params.to_json,
        headers: bearer(subject, **token_options).merge("CONTENT_TYPE" => "application/json")
    end

    it "routes a confirmed same-person email to the claim path and attaches the link after step-up" do
      client_user
      clerk_account!("user_client", email: "riley.own@example.net")
      expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /confirm this is the same person/)

      invite = invite!(employee, actor: staff, confirm_same_person_email: true)
      expect(invite).to have_attributes(path: "claim")
      expect(invite.link.claim_user_id).to eq(client_user.id)
      expect(AuditLog.where(action: "employees#confirm_same_person_email", record_id: employee.id).count).to eq(1)

      # A new account can't be started for this invite.
      post_activation(activation_params(employee, token: invite.token, email: "someone.else@example.net"))
      expect(response.parsed_body["next"]).to eq("sign_in")

      # MFA is off here, so the step-up is a fresh first factor; an old one is refused.
      claim("user_client", activation_params(employee, token: invite.token), fva: [ 30, 30 ], two_factor_enabled: true)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("clerk_error", "reason")).to eq("reverification-error")
      expect(response.parsed_body.dig("clerk_error", "metadata", "reverification", "level")).to eq("first_factor")
      expect(invite.link.reload).to be_invited

      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("link", "id")).to eq(invite.link.id)
      expect(invite.link.reload).to have_attributes(status: "active", user_id: client_user.id, invite_token_digest: nil)
      expect(link_audits(invite.link, "claimed").sole).to have_attributes(actor_type: "client_user", user_id: client_user.id)
      expect(clerk).not_to have_received(:create_invitation)

      get "/api/v1/auth/me", headers: bearer("user_client", **fresh_second_factor)
      expect(response.parsed_body.fetch("roles")).to include("client" => true, "employee_links_count" => 1)
    end

    it "lets a staff member claim their own company employee record with a printed code" do
      staffer = create(:user, role: :accountant, company: company, name: "Riley Santos", clerk_id: "user_staffer")
      invite = invite!(employee, actor: staff, delivery: "code")

      claim("user_staffer", activation_params(employee, code: invite.code), **fresh_second_factor)

      expect(response).to have_http_status(:created)
      expect(invite.link.reload).to have_attributes(status: "active", user_id: staffer.id)
    end

    it "refuses with one 404 for another person's login, a different routed login, a deactivated login and bad details" do
      stranger = create(:user, role: :client, company: company, name: "Someone Else", clerk_id: "user_stranger")
      namesake = create(:user, role: :client, company: company, name: "Riley Santos", clerk_id: "user_namesake")
      client_user
      routed = invite!(employee, actor: staff, confirm_same_person_email: true)

      claim("user_stranger", activation_params(employee, token: routed.token), **fresh_second_factor)
      expect(response).to have_http_status(:not_found)
      claim("user_namesake", activation_params(employee, token: routed.token), **fresh_second_factor)
      expect(response).to have_http_status(:not_found)
      body = response.parsed_body
      claim("user_client", activation_params(employee, token: routed.token, ssn_last4: "0000"), **fresh_second_factor)
      expect([ response.status, response.parsed_body ]).to eq([ 404, body ])

      client_user.update!(active: false)
      claim("user_client", activation_params(employee, token: routed.token), **fresh_second_factor)
      expect(response).to have_http_status(:not_found)
      expect(routed.link.reload).to have_attributes(status: "invited", user_id: nil)
      expect([ stranger, namesake ].map { |user| user.reload.employee_account_links }).to all(be_empty)
    end

    it "retires a printed code with no recorded staff issuer for claims too" do
      staffer = create(:user, role: :accountant, company: company, name: "Riley Santos", clerk_id: "user_staffer")
      invite = invite!(employee, actor: staff, delivery: "code")
      invite.link.update_columns(invite_code_issued_by_staff: nil)

      claim("user_staffer", activation_params(employee, code: invite.code), **fresh_second_factor)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::CODE_RETIRED, "code" => "code_retired")
      expect(invite.link.reload.user_id).not_to eq(staffer.id)
    end

    it "takes a ticket-verified primary as proof only when the current invite was emailed to it" do
      client_user
      invite = invite!(employee, actor: staff, confirm_same_person_email: true)
      ticket = lambda do |email|
        allow(clerk).to receive(:fetch_user).with("user_client").and_return(
          "id" => "user_client", "primary_email_address_id" => "idn",
          "email_addresses" => [ { "id" => "idn", "email_address" => email,
                                   "verification" => { "status" => "verified", "strategy" => "ticket" } } ]
        )
      end

      # The invite went to an older address; the ticket proves nothing about this one.
      invite.link.update_columns(invite_email: "riley.old@example.net")
      ticket.call("riley.own@example.net")
      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["code"]).to eq("email_mismatch")

      # The current invite was emailed to it: the invite link proved the inbox.
      invite.link.update_columns(invite_email: "riley.own@example.net")
      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:created)
    end

    it "refuses a claim when the signed-in Clerk account's verified primary email isn't the one on file" do
      client_user
      invite = invite!(employee, actor: staff, confirm_same_person_email: true)
      clerk_account!("user_client", email: "riley.work@example.net")

      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::EMAIL_MISMATCH, "code" => "email_mismatch")

      clerk_account!("user_client", email: "riley.own@example.net", status: "unverified")
      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:forbidden)
      expect(invite.link.reload).to have_attributes(status: "invited", user_id: nil, failed_activation_attempts: 0)

      clerk_account!("user_client", email: "Riley.Own@example.net ")
      claim("user_client", activation_params(employee, token: invite.token), **fresh_second_factor)
      expect(response).to have_http_status(:created)
    end

    it "closes an abandoned pending sign-up when the person claims with their existing login instead" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "abandoned@example.net"))
      pending_user = invite.link.reload.user
      staffer = create(:user, role: :accountant, company: company, name: "Riley Santos", clerk_id: "user_staffer")

      claim("user_staffer", activation_params(employee, code: invite.code), **fresh_second_factor)

      expect(response).to have_http_status(:created)
      expect(invite.link.reload.user_id).to eq(staffer.id)
      expect(pending_user.reload).to have_attributes(active: false, invite_nonce_digest: nil)
      expect(clerk).to have_received(:revoke_invitation).with("inv_1")
    end
  end
end
