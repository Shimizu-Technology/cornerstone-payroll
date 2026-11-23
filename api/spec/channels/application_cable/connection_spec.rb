# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:user) { create(:user, company: company, organization: organization, role: "admin") }

  before do
    allow_any_instance_of(described_class).to receive(:auth_disabled?).and_return(false)
  end

  def issue_ticket
    CableTicketService.issue!(user: user, company_id: company.id)
  end

  it "connects an active user in an active organization" do
    connect params: { ticket: issue_ticket }

    expect(connection.current_user).to eq(user)
    expect(connection.current_company).to eq(company)
  end

  it "rejects an inactive user even when the ticket was issued before deactivation" do
    ticket = issue_ticket
    user.update_columns(active: false)

    expect { connect params: { ticket: ticket } }.to have_rejected_connection
  end

  it "rejects a regular user in an inactive organization" do
    ticket = issue_ticket
    organization.update_columns(status: "inactive")

    expect { connect params: { ticket: ticket } }.to have_rejected_connection
  end

  it "allows an active super admin to recover an inactive organization" do
    user.update!(role: "super_admin")
    ticket = issue_ticket
    organization.update_columns(status: "inactive")

    connect params: { ticket: ticket }

    expect(connection.current_user).to eq(user)
    expect(connection.current_company).to eq(company)
  end

  it "rejects an array-valued ticket without raising a digest error" do
    expect { connect params: { ticket: [ "invalid" ] } }.to have_rejected_connection
  end

  describe "MFA at connection time" do
    around do |example|
      previous = ENV["REQUIRE_MFA"]
      ENV["REQUIRE_MFA"] = "false"
      example.run
    ensure
      ENV["REQUIRE_MFA"] = previous
    end

    it "rejects a ticket issued before enforcement was enabled" do
      ticket = issue_ticket
      ENV["REQUIRE_MFA"] = "true"

      expect do
        connect params: { ticket: ticket }, headers: { "User-Agent" => "Cable connection spec" },
          env: { "REMOTE_ADDR" => "192.0.2.81" }
      end.to have_rejected_connection
      expect(AuditLog.last).to have_attributes(
        action: "authentication#mfa_required_denied", event_category: "security", metadata: { "source" => "action_cable" },
        subject_name: user.name, ip_address: "192.0.2.81", user_agent: "Cable connection spec"
      )
    end

    it "accepts a verified ticket once and retains the ticket's company scope" do
      ENV["REQUIRE_MFA"] = "true"
      ticket = CableTicketService.issue!(user: user, company_id: company.id, clerk_token_payload: { "fva" => [ 5, 0 ] })

      connect params: { ticket: ticket }

      expect(connection.current_user).to eq(user)
      expect(connection.current_company).to eq(company)
      expect { connect params: { ticket: ticket } }.to have_rejected_connection
    end
  end
end
