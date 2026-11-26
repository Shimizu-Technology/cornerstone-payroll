# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll intake profile", type: :request do
  it "discovers enabled adapters through the same descriptor endpoint for different clients" do
    pending "Track C B2 adds the descriptor registry and intake profile endpoint"
    %w[mosa_revel spike_email].each do |adapter|
      company = create(:company, payroll_intake_source_types: [ adapter ])
      staff = create(:user, company: company, role: "admin")
      stub_portal_user(Api::V1::Admin::CompaniesController, staff, company)

      get "/api/v1/admin/companies/#{company.id}/intake_profile"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("adapters").pluck("key")).to eq([ adapter ])
    end
  end
end
