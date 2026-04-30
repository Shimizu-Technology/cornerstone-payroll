# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Auth", type: :request do
  describe "POST /api/v1/cable_ticket" do
    before do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    end

    it "returns a short-lived cable ticket for the current company" do
      cache = ActiveSupport::Cache::MemoryStore.new
      company = create(:company)
      user = create(:user, company: company, role: "admin")
      allow(Rails).to receive(:cache).and_return(cache)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)

      post "/api/v1/cable_ticket"

      expect(response).to have_http_status(:created)
      ticket = response.parsed_body.fetch("ticket")
      expect(ticket).to be_present
      expect(CableTicketService.consume(ticket)).to include("user_id" => user.id, "company_id" => company.id)
    end
  end

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
      expect(response.parsed_body.fetch("user")).to include(
        "id" => user.id,
        "role" => "admin",
        "home_company_id" => company.id,
        "assigned_company_ids" => [ company.id ]
      )
      expect(response.parsed_body.fetch("user")).not_to have_key("super_admin")
    end
  end
end
