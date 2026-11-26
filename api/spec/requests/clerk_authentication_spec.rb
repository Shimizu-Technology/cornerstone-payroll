# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clerk Authentication", type: :request do
  let(:organization) { Organization.first || create(:organization, name: "Test Organization") }
  let(:company) { Company.first || Company.create!(name: "Test Company", organization: organization) }
  let(:user) do
    User.create!(
      company: company,
      email: "auth-spec@example.com",
      name: "Auth Spec User",
      clerk_id: "user_test123",
      role: "admin"
    )
  end

  # Use a real-ish JWT structure for testing
  let(:valid_clerk_id) { user.clerk_id }

  before do
    # Enable auth for these tests
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
  end

  describe "JWT verification" do
    it "rejects requests without Authorization header" do
      get "/api/v1/admin/employees"
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Authorization header missing")
    end

    it "rejects requests with invalid token" do
      allow_any_instance_of(ClerkTokenVerifier).to receive(:fetch_jwks).and_return([])

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer invalid.token.here" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid or expired token")
    end

    it "audits unauthenticated portal failures as system events without resource details" do
      get "/api/v1/client/portal_threads/123456", headers: { "X-Request-Id" => "unauthenticated-portal" }

      expect(response).to have_http_status(:unauthorized)
      expect(AuditLog.find_by!(action: "portal_access#failed", request_id: "unauthenticated-portal")).to have_attributes(
        user_id: nil, company_id: nil, record_id: nil, subject_name: nil,
        actor_type: "system_job", actor_name: "Portal Access", event_category: "security",
        metadata: { "status" => 401, "reason" => "request_failed", "operation" => "show" }
      )
    end

    it "rejects requests with malformed Authorization header" do
      get "/api/v1/admin/employees", headers: { "Authorization" => "NotBearer token" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Authorization header missing")
    end
  end

  describe "token expiration" do
    it "rejects expired tokens" do
      # Stub verify_clerk_token to simulate expired token
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return(nil)

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer expired.token.here" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "invitation-only identity binding" do
    let(:subject_id) { "user_new456" }
    let(:headers) { { "Authorization" => "Bearer valid.token" } }
    let(:nonce) { "a" * 64 }
    let(:provider) { instance_double(ClerkInvitationService) }
    let(:provider_user) do
      {
        "id" => subject_id,
        "public_metadata" => {},
        "primary_email_address_id" => "primary",
        "email_addresses" => [ { "id" => "primary", "email_address" => user.email,
          "verification" => { "status" => "verified" } } ]
      }
    end

    before do
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return("sub" => subject_id)
      allow(ClerkInvitationService).to receive(:new).and_return(provider)
      allow(provider).to receive(:fetch_user).with(subject_id).and_return(provider_user)
    end

    def issue_pending_invite!
      user.update!(clerk_id: "pending_synthetic", invitation_status: "pending", clerk_invitation_id: "inv_synthetic",
        invite_nonce_digest: Digest::SHA256.hexdigest(nonce), invite_nonce_expires_at: 1.day.from_now)
      provider_user["public_metadata"] = { "payroll_user_id" => user.id, "payroll_invite_nonce" => nonce, "role" => "super_admin" }
      allow(provider).to receive(:invitation_status).with("inv_synthetic").and_return("accepted")
    end

    def authenticate
      get "/api/v1/auth/me", headers: headers
    end

    it "binds by provider metadata, ignores provider role, and consumes the nonce with a security audit" do
      issue_pending_invite!

      expect { authenticate }.to change(AuditLog.where(action: "authentication#clerk_identity_bound"), :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(clerk_id: subject_id, invitation_status: "accepted", role: "admin",
        invite_nonce_digest: nil, invite_nonce_expires_at: nil)
      expect(AuditLog.find_by!(action: "authentication#clerk_identity_bound")).to have_attributes(
        user_id: user.id, record_id: user.id, event_category: "security")
    end

    [
      [ { "sub" => "user_new456" }, "mfa_enrollment_required", MfaPolicy::ENROLLMENT_REQUIRED_MESSAGE ],
      [ { "sub" => "user_new456", "two_factor_enabled" => true, "fva" => [ 0, -1 ] }, "mfa_required", MfaPolicy::ERROR_MESSAGE ]
    ].each do |claims, code, message|
      it "checks MFA before binding an accepted invitation or opening a business scope (#{code})" do
        issue_pending_invite!
        allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return(claims)
        allow(MfaPolicy).to receive(:enabled?).and_return(true)
        expect(TenantScope).not_to receive(:with_company)
        allow(TenantScope).to receive(:as_system).and_call_original
        expect(TenantScope).not_to receive(:as_system).with(reason: "Bind authorized Clerk invitation")
        expect(TenantScope).not_to receive(:as_system).with(reason: "Resolve linked employee accounts for authenticated user")

        expect { authenticate }.to change(AuditLog.where(action: "authentication#mfa_required_denied"), :count).by(1)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("mfa_required" => true, "mfa_verified" => false, "code" => code, "error" => message)
        expect(user.reload).to have_attributes(clerk_id: "pending_synthetic", invitation_status: "pending",
          invite_nonce_digest: Digest::SHA256.hexdigest(nonce))
        expect(AuditLog.where(action: "authentication#clerk_identity_bound")).to be_empty
      end
    end

    it "leaves the invitation intact during maintenance and binds the same sign-in afterward" do
      issue_pending_invite!
      allow(WriteMaintenance).to receive(:enabled?).and_return(true)
      audit = AuditLog.where(action: "authentication#clerk_identity_bound")

      expect { authenticate }.not_to change { [ user.reload.attributes, audit.count ] }
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("code" => "write_maintenance", "error" => /Try again shortly/)
      expect(provider).not_to have_received(:fetch_user)

      allow(WriteMaintenance).to receive(:enabled?).and_return(false)
      expect { authenticate }.to change(audit, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(clerk_id: subject_id, invitation_status: "accepted")
    end

    it "also records the domain audit when a first request binds and performs a write" do
      issue_pending_invite!

      post "/api/v1/admin/departments", headers: headers, params: { department: { name: "Test Department" } }

      expect(response).to have_http_status(:created)
      expect(AuditLog.where(user_id: user.id).pluck(:action)).to include("authentication#clerk_identity_bound", "departments#create")
    end

    it "binds a client created by Google sign-up when Clerk carries the invitation metadata" do
      user.update!(role: "client")
      CompanyAssignment.create!(user: user, company: company)
      issue_pending_invite!
      provider_user["external_accounts"] = [ { "provider" => "oauth_google", "email_address" => "google@example.test" } ]
      provider_user["email_addresses"].first["email_address"] = "google@example.test"
      provider_user["unsafe_metadata"] = { "payroll_user_id" => user.id + 1 }

      get "/api/v1/client/employees", headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.reload).to have_attributes(clerk_id: subject_id, email: "auth-spec@example.com")
    end

    it "returns 403 for a bound client with no active company assignment" do
      user.update!(role: "client")
      issue_pending_invite!

      get "/api/v1/client/employees", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(user.reload).to have_attributes(clerk_id: subject_id, invitation_status: "accepted")
    end

    it "rejects an email match on an already bound, pending, or unbound local row" do
      [ user.clerk_id, "pending_legacy", nil ].each do |local_subject|
        user.update!(clerk_id: local_subject, invitation_status: local_subject == "pending_legacy" ? "pending" : "accepted")

        expect { authenticate }.not_to change(User, :count)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["code"]).to eq("payroll_account_unbound")
        expect(user.reload.clerk_id).to eq(local_subject)
      end
    end

    it "does not provision a user from a legacy email invitation" do
      invite = UserInvitation.create!(company: company, invited_by: user, email: "legacy@example.test",
        role: "client", token: SecureRandom.hex(32), invited_at: Time.current, expires_at: 1.day.from_now)
      provider_user["email_addresses"].first["email_address"] = invite.email

      expect { authenticate }.not_to change(User, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(invite.reload.accepted_at).to be_nil
    end

    it "leaves a bound user signed in without reading Clerk user metadata" do
      allow(WriteMaintenance).to receive(:enabled?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return("sub" => user.clerk_id)
      expect(provider).not_to receive(:fetch_user)

      authenticate

      expect(response).to have_http_status(:ok)
    end

    it "rejects missing, mismatched, or frontend-writable nonce metadata" do
      issue_pending_invite!
      public_metadata = provider_user.fetch("public_metadata")
      provider_user["unsafe_metadata"] = public_metadata.dup

      [ nil, "b" * 64 ].each do |invalid_nonce|
        public_metadata["payroll_invite_nonce"] = invalid_nonce
        authenticate

        expect(response).to have_http_status(:unauthorized)
        expect(user.reload.clerk_id).to eq("pending_synthetic")
      end
    end

    it "rejects an expired nonce or revoked invitation" do
      issue_pending_invite!
      user.update!(invite_nonce_expires_at: 1.second.ago)

      authenticate
      expect(response).to have_http_status(:unauthorized)

      user.update!(invite_nonce_expires_at: 1.day.from_now)
      allow(provider).to receive(:invitation_status).with("inv_synthetic").and_return("revoked")

      authenticate
      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.clerk_id).to eq("pending_synthetic")
    end

    it "rejects replay by a second Clerk account" do
      issue_pending_invite!
      authenticate
      expect(response).to have_http_status(:ok)

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return("sub" => "user_replay")
      allow(provider).to receive(:fetch_user).with("user_replay").and_return(provider_user.merge("id" => "user_replay"))

      expect { authenticate }.not_to change(AuditLog.where(action: "authentication#clerk_identity_bound"), :count)
      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.clerk_id).to eq(subject_id)
    end

    it "rejects a uniqueness collision without falling back to email" do
      issue_pending_invite!
      allow_any_instance_of(User).to receive(:update!).and_raise(ActiveRecord::RecordNotUnique)

      authenticate

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.clerk_id).to eq("pending_synthetic")
    end

    it "rolls back a metadata binding if its security audit cannot be written" do
      issue_pending_invite!
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

      authenticate

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.clerk_id).to eq("pending_synthetic")
      expect(user.invite_nonce_digest).to be_present
    end
  end

  describe "authenticated activity auditing" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => valid_clerk_id,
        "sid" => "session-audit-123"
      })
    end

    it "records the session marker and sign-in audit together and clears the request actor" do
      expect(user).to be_persisted
      allow(AuditLog).to receive(:record!).and_wrap_original do |method, **attributes|
        expect(Current.actor).to eq(AuditActor.for_user(user))
        method.call(**attributes)
      end

      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.to change {
        AuditLog.where(action: "authentication#signed_in", user_id: user.id).count
      }.by(1)

      expect(response).to have_http_status(:ok)
      expect(user.reload.last_session_id_digest).to eq(Digest::SHA256.hexdigest("session-audit-123"))
      expect(user.last_login_at).to be_present
      expect(Current.actor).to be_nil

      get "/api/v1/admin/employees"
      expect(response).to have_http_status(:unauthorized)
      expect(Current.actor).to be_nil
    end

    it "does not lock the user row when no activity write is due" do
      user.update_columns(
        last_session_id_digest: Digest::SHA256.hexdigest("session-audit-123"),
        last_active_at: Time.current
      )
      expect_any_instance_of(User).not_to receive(:with_lock)

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:ok)
    end

    it "rolls back the session marker when the sign-in audit fails so a later request can retry" do
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit unavailable")

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.last_session_id_digest).to be_nil
      expect(user.last_login_at).to be_nil
      expect(user.last_active_at).to be_nil
    end
  end

  describe "local account access policy" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => valid_clerk_id
      })
    end

    it "rejects an inactive local user even with a valid Clerk token" do
      user.update!(active: false)

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Account inactive")
    end

    it "rejects a regular user whose organization is inactive" do
      organization.update!(status: "inactive")

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Account inactive")
    end

    it "preserves super-admin recovery access to an inactive organization" do
      user.update!(role: "super_admin")
      organization.update!(status: "inactive")

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "auth bypass" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    end

    around do |example|
      original_e2e_test_mode = ENV["E2E_TEST_MODE"]
      example.run
    ensure
      ENV["E2E_TEST_MODE"] = original_e2e_test_mode
    end

    it "allows requests when AUTH_ENABLED is false" do
      user

      get "/api/v1/admin/employees"
      expect(response).not_to have_http_status(:unauthorized)
    end

    it "ignores the test identity header unless the explicit test mode is enabled" do
      user
      client = create(:user, company: company, organization: organization, role: "client")
      ENV.delete("E2E_TEST_MODE")

      get "/api/v1/admin/employees", headers: { "X-E2E-User-Email" => client.email }

      expect(response).to have_http_status(:ok)
    end

    it "selects a scoped test identity only in test mode" do
      user
      client = create(:user, company: company, organization: organization, role: "client")
      ENV["E2E_TEST_MODE"] = "true"

      get "/api/v1/admin/employees", headers: { "X-E2E-User-Email" => client.email }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Staff access required")
    end

    it "does not let the test identity header reactivate an inactive account" do
      inactive_user = create(:user, company: company, organization: organization, active: false)
      ENV["E2E_TEST_MODE"] = "true"

      get "/api/v1/auth/me", headers: { "X-E2E-User-Email" => inactive_user.email }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
