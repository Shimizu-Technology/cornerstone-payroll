# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Explicit company access with Clerk authentication", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company, organization: company.organization, role: role, clerk_id: "user_explicit_company") }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:claims) { { "sub" => user.clerk_id, "fva" => [ 1, 0 ] } }

  around do |example|
    previous = ENV.to_h.slice("AUTH_ENABLED", "REQUIRE_MFA")
    ENV.update("AUTH_ENABLED" => "true", "REQUIRE_MFA" => "true")
    example.run
  ensure
    %w[AUTH_ENABLED REQUIRE_MFA].each { |key| ENV[key] = previous[key] }
  end

  before do
    verifier = instance_double(ClerkTokenVerifier)
    allow(verifier).to receive(:verify).with("synthetic.token").and_return(claims)
    allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
  end

  def headers(company_id)
    { "Authorization" => "Bearer synthetic.token", "X-Company-Id" => company_id.to_s }
  end

  %w[super_admin admin].each do |staff_role|
    context "as #{staff_role}" do
      let(:role) { staff_role }

      it "rejects invalid and stale selections on both payroll endpoints before opening company scope" do
        payroll_id = period.id
        inactive = create(:company, organization: company.organization, active: false)
        unavailable = [ "not-an-id", "", "9999999999", inactive.id.to_s ]
        unavailable << create(:company).id.to_s unless role == "super_admin"
        expect(TenantScope).not_to receive(:with_company)

        unavailable.each do |selection|
          get "/api/v1/admin/pay_periods", headers: headers(selection)
          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body.fetch("code")).to eq("company_context_unavailable")

          get "/api/v1/form_500s/defaults", params: { pay_period_id: payroll_id }, headers: headers(selection)
          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body.fetch("code")).to eq("company_context_unavailable")
        end
      end

      it "keeps valid explicit company selections working on both payroll endpoints" do
        payroll_id = period.id
        get "/api/v1/admin/pay_periods", headers: headers(company.id)
        expect(response).to have_http_status(:ok)

        get "/api/v1/form_500s/defaults", params: { pay_period_id: payroll_id }, headers: headers(company.id)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "company_name")).to eq(company.name)
      end
    end
  end

  context "as a client user" do
    let(:role) { "client" }

    it "validates explicit selections before the client scope and Cable ticket issuance" do
      get "/api/v1/client/employees", headers: headers("not-an-id")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("code")).to eq("company_context_unavailable")

      expect { post "/api/v1/cable_ticket", headers: headers("9999999999") }.not_to change(CableConnectionTicket, :count)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("code")).to eq("company_context_unavailable")
    end
  end

  context "with unverified MFA" do
    let(:role) { "super_admin" }

    it "returns the MFA denial before checking a malformed header" do
      claims["fva"] = [ 1, -1 ]
      get "/api/v1/admin/pay_periods", headers: headers("not-an-id")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("code")).to eq("mfa_required")
    end
  end
end
