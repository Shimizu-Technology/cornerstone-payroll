# frozen_string_literal: true

require "rails_helper"

RSpec.describe CableTicketService do
  describe ".issue!" do
    it "rejects direct issuance for unverified staff even without an HTTP controller" do
      user = create(:user, role: :admin)
      allow(MfaPolicy).to receive(:enabled?).and_return(true)
      request = instance_double(ActionDispatch::Request, request_id: "cable-issue",
        remote_ip: "192.0.2.52", user_agent: "Cable issuance spec")

      expect do
        described_class.issue!(user: user, company_id: user.company_id, clerk_token_payload: { "fva" => [ 5, -1 ] },
          request: request)
      end.to raise_error(MfaPolicy::VerificationRequired)

      expect(CableConnectionTicket.count).to eq(0)
      expect(AuditLog.last).to have_attributes(
        action: "authentication#mfa_required_denied", event_category: "security", metadata: { "source" => "cable_ticket" },
        request_id: "cable-issue", subject_name: user.name, ip_address: "192.0.2.52", user_agent: "Cable issuance spec"
      )
    end

    it "does not honor the development auth bypass in production" do
      user = create(:user, role: :admin)
      allow(MfaPolicy).to receive(:enabled?).and_return(true)
      allow(Rails.env).to receive(:production?).and_return(true)

      expect do
        described_class.issue!(user: user, company_id: user.company_id, auth_disabled: true)
      end.to raise_error(MfaPolicy::VerificationRequired)
    end

    it "removes stale consumed or expired tickets before issuing a new ticket" do
      company = create(:company)
      user = create(:user, company: company)
      create(:cable_connection_ticket, user: user, company: company, expires_at: 2.days.ago)
      create(:cable_connection_ticket, user: user, company: company, expires_at: 1.hour.from_now, used_at: 1.minute.ago)
      active = create(:cable_connection_ticket, user: user, company: company, expires_at: 1.hour.from_now)

      ticket = described_class.issue!(user: user, company_id: company.id)

      expect(ticket).to be_present
      expect(CableConnectionTicket.exists?(active.id)).to be(true)
      expect(CableConnectionTicket.count).to eq(2)
    end

    it "stores only a digest of the raw ticket" do
      company = create(:company)
      user = create(:user, company: company)

      ticket = described_class.issue!(user: user, company_id: company.id)
      stored_ticket = CableConnectionTicket.last

      expect(stored_ticket.token_digest).not_to eq(ticket)
      expect(stored_ticket.token_digest).to eq(described_class.token_digest(ticket))
    end
  end

  describe ".consume" do
    it "ignores non-string query values" do
      expect(described_class.consume([ "ticket" ])).to be_nil
      expect(described_class.consume({ "ticket" => "nested" })).to be_nil
    end

    it "consumes a ticket only once" do
      company = create(:company)
      user = create(:user, company: company)
      ticket = described_class.issue!(user: user, company_id: company.id)

      expect(described_class.consume(ticket)).to include("user_id" => user.id, "company_id" => company.id)
      expect(described_class.consume(ticket)).to be_nil
    end
  end
end
