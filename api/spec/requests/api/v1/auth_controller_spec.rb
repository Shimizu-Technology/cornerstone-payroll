# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Auth", type: :request do
  describe "GET /api/v1/auth/me" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    end

    it "returns unauthorized when no current user exists" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(nil)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Not authenticated")
    end

    it "returns current user data when available" do
      company = create(:company)
      user = User.create!(
        company: company,
        email: "auth-test-#{company.id}@example.com",
        name: "Auth Test User",
        role: "admin",
        active: true
      )
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      get "/api/v1/auth/me"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "id")).to eq(user.id)
    end
  end
end
