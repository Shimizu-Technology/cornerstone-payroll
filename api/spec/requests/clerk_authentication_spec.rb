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
      allow_any_instance_of(ApplicationController).to receive(:fetch_jwks).and_return([])

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer invalid.token.here" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid or expired token")
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

  describe "user auto-provisioning" do
    let(:clerk_user_response) do
      {
        "id" => "user_new456",
        "first_name" => "New",
        "last_name" => "User",
        "primary_email_address_id" => "email_new_primary",
        "email_addresses" => [ {
          "id" => "email_new_primary",
          "email_address" => "new@example.com",
          "verification" => { "status" => "verified" }
        } ]
      }
    end

    it "bootstraps the first user as an admin only when explicitly allowed" do
      User.delete_all
      Company.delete_all
      Organization.delete_all
      original_bootstrap_setting = ENV["ALLOW_INITIAL_ADMIN_BOOTSTRAP"]
      ENV["ALLOW_INITIAL_ADMIN_BOOTSTRAP"] = "true"

      begin
        # Stub the auth chain to simulate a valid token for unknown user
        allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
          "sub" => "user_new456"
        })
        allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
          .with("user_new456").and_return(clerk_user_response)

        expect {
          get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
        }.to change(User, :count).by(1)

        new_user = User.find_by(clerk_id: "user_new456")
        expect(new_user).to be_present
        expect(new_user.email).to eq("new@example.com")
        expect(new_user.name).to eq("New User")
        expect(new_user.role).to eq("admin")
        expect(new_user.company).to be_present
      ensure
        ENV["ALLOW_INITIAL_ADMIN_BOOTSTRAP"] = original_bootstrap_setting
      end
    end

    it "rejects unknown first users when bootstrap is not explicitly enabled" do
      User.delete_all
      Company.delete_all
      Organization.delete_all

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_new456"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_new456").and_return(clerk_user_response)

      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects unknown users when the system has already been bootstrapped" do
      User.create!(
        company: company,
        email: "existing-admin@example.com",
        name: "Existing Admin",
        clerk_id: "user_existing_admin",
        role: "admin"
      )

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_new456"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_new456").and_return(clerk_user_response)

      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "links existing user by email when clerk_id differs" do
      existing = User.create!(
        company: company,
        email: "existing@example.com",
        name: "Existing User",
        clerk_id: nil,
        role: "employee"
      )

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_existing789"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_existing789").and_return({
          "id" => "user_existing789",
          "first_name" => "Existing",
          "last_name" => "User",
          "primary_email_address_id" => "email_existing_primary",
          "email_addresses" => [ {
            "id" => "email_existing_primary",
            "email_address" => "existing@example.com",
            "verification" => { "status" => "verified" }
          } ]
        })

      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.not_to change(User, :count)

      existing.reload
      expect(existing.clerk_id).to eq("user_existing789")
    end

    it "links only the verified primary email when Clerk returns multiple addresses" do
      primary_user = User.create!(
        company: company,
        email: "primary@example.com",
        name: "Primary User",
        clerk_id: nil,
        role: "employee"
      )
      secondary_user = User.create!(
        company: company,
        email: "secondary@example.com",
        name: "Secondary User",
        clerk_id: nil,
        role: "employee"
      )

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_primary789"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_primary789").and_return({
          "id" => "user_primary789",
          "primary_email_address_id" => "email_primary",
          "email_addresses" => [
            {
              "id" => "email_secondary",
              "email_address" => "secondary@example.com",
              "verification" => { "status" => "verified" }
            },
            {
              "id" => "email_primary",
              "email_address" => "primary@example.com",
              "verification" => { "status" => "verified" }
            }
          ]
        })

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:forbidden)
      expect(primary_user.reload.clerk_id).to eq("user_primary789")
      expect(secondary_user.reload.clerk_id).to be_nil
    end

    it "rejects an unverified primary email without linking a local account" do
      existing = User.create!(
        company: company,
        email: "unverified@example.com",
        name: "Unverified User",
        clerk_id: nil,
        role: "employee"
      )

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_unverified789"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_unverified789").and_return({
          "id" => "user_unverified789",
          "primary_email_address_id" => "email_unverified",
          "email_addresses" => [ {
            "id" => "email_unverified",
            "email_address" => "unverified@example.com",
            "verification" => { "status" => "unverified" }
          } ]
        })

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      expect(response).to have_http_status(:unauthorized)
      expect(existing.reload.clerk_id).to be_nil
    end
  end

  describe "race condition handling" do
    it "handles concurrent user creation gracefully" do
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_race123"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_race123").and_return({
          "id" => "user_race123",
          "first_name" => "Race",
          "last_name" => "Condition",
          "primary_email_address_id" => "email_race_primary",
          "email_addresses" => [ {
            "id" => "email_race_primary",
            "email_address" => "race@example.com",
            "verification" => { "status" => "verified" }
          } ]
        })

      race_user = User.create!(
        company: company,
        email: "race@example.com",
        name: "Race User",
        clerk_id: nil,
        role: "employee"
      )
      # Simulate RecordNotUnique by stubbing User.create! to raise, then find
      allow(User).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with("LOWER(email) = ?", "race@example.com").and_return(race_user)

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      # Should not 500 — handles the race gracefully
      expect(response.status).not_to eq(500)
    end
  end

  describe "authenticated activity auditing" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => valid_clerk_id,
        "sid" => "session-audit-123"
      })
    end

    it "records the session marker and sign-in audit together" do
      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.to change {
        AuditLog.where(action: "authentication#signed_in", user_id: user.id).count
      }.by(1)

      expect(response).to have_http_status(:ok)
      expect(user.reload.last_session_id_digest).to eq(Digest::SHA256.hexdigest("session-audit-123"))
      expect(user.last_login_at).to be_present
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

    it "allows requests when AUTH_ENABLED is false" do
      get "/api/v1/admin/employees"
      expect(response).not_to have_http_status(:unauthorized)
    end
  end
end
