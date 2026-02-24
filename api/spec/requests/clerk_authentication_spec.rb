# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clerk Authentication", type: :request do
  let(:company) { Company.first || create(:company) }
  let(:user) { create(:user, company: company, clerk_id: "user_test123", role: "admin") }

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
        "email_addresses" => [{ "email_address" => "new@example.com" }]
      }
    end

    it "provisions a new user when clerk_id is not found" do
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
      expect(new_user.role).to eq("employee")
    end

    it "links existing user by email when clerk_id differs" do
      existing = create(:user, company: company, email: "existing@example.com", clerk_id: nil)

      allow_any_instance_of(ApplicationController).to receive(:verify_clerk_token).and_return({
        "sub" => "user_existing789"
      })
      allow_any_instance_of(ApplicationController).to receive(:fetch_clerk_user)
        .with("user_existing789").and_return({
          "id" => "user_existing789",
          "first_name" => "Existing",
          "last_name" => "User",
          "email_addresses" => [{ "email_address" => "existing@example.com" }]
        })

      expect {
        get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }
      }.not_to change(User, :count)

      existing.reload
      expect(existing.clerk_id).to eq("user_existing789")
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
          "email_addresses" => [{ "email_address" => "race@example.com" }]
        })

      # Simulate RecordNotUnique by stubbing User.create! to raise, then find
      allow(User).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
      race_user = create(:user, company: company, email: "race@example.com", clerk_id: nil)
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(email: "race@example.com").and_return(race_user)

      get "/api/v1/admin/employees", headers: { "Authorization" => "Bearer valid.token" }

      # Should not 500 — handles the race gracefully
      expect(response.status).not_to eq(500)
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
