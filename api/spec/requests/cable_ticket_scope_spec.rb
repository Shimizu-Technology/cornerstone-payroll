# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Native Cable ticket company scope", type: :request do
  let(:organization) { create(:organization) }
  let(:home) { create(:company, organization: organization) }
  let(:client) { create(:company, organization: organization) }
  let(:user) { create(:user, company: home, organization: organization, role: "accountant", platform_owner: false) }

  before do
    actor_id = user.id
    allow_any_instance_of(Api::V1::CableTicketsController).to receive(:current_user) { User.find(actor_id) }
    allow_any_instance_of(Api::V1::Admin::PortalThreadsController).to receive(:current_user) { User.find(actor_id) }
  end

  it "does not issue a home-company ticket for an explicitly inaccessible client" do
    expect { post "/api/v1/cable_ticket", headers: { "X-Company-Id" => client.id.to_s } }
      .not_to change(CableConnectionTicket, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects a malformed explicit client without falling back home" do
    expect { post "/api/v1/cable_ticket", headers: { "X-Company-Id" => "#{home.id}invalid" } }
      .not_to change(CableConnectionTicket, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "issues the assigned client's ticket and denies another ticket after removal" do
    assignment = CompanyAssignment.create!(user: user, company: client)
    post "/api/v1/cable_ticket", headers: { "X-Company-Id" => client.id.to_s }
    expect(response).to have_http_status(:created)
    expect(CableConnectionTicket.last.company_id).to eq(client.id)
    assignment.destroy!
    user.reload
    expect { post "/api/v1/cable_ticket", headers: { "X-Company-Id" => client.id.to_s } }
      .not_to change(CableConnectionTicket, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it "preserves no-header home-company access" do
    post "/api/v1/cable_ticket"
    expect(response).to have_http_status(:created)
    expect(CableConnectionTicket.last.company_id).to eq(home.id)
  end

  it "issues a development ticket with MFA enabled when Clerk auth is disabled" do
    previous_auth = ENV["AUTH_ENABLED"]
    previous_mfa = ENV["REQUIRE_MFA"]
    ENV["AUTH_ENABLED"] = "false"
    ENV["REQUIRE_MFA"] = "true"

    expect { post "/api/v1/cable_ticket" }.to change(CableConnectionTicket, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("ticket")).to match(/\A[A-Za-z0-9_-]{43}\z/)
    expect(AuditLog.where(action: "authentication#mfa_required_denied")).to be_empty
  ensure
    ENV["AUTH_ENABLED"] = previous_auth
    ENV["REQUIRE_MFA"] = previous_mfa
  end

  it "does not create a home-company conversation for a revoked explicit client" do
    expect do
      post "/api/v1/admin/portal_threads", headers: { "X-Company-Id" => client.id.to_s },
        params: { subject: "Synthetic scope check", body: "This must not be saved to the home company" }
    end.not_to change(ClientPortalThread, :count)
    expect(response).to have_http_status(:forbidden)
    expect(ClientPortalMessage.count).to eq(0)
  end
end
