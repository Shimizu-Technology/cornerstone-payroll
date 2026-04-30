# frozen_string_literal: true

require "rails_helper"

RSpec.describe CableTicketService do
  describe ".issue!" do
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
    it "consumes a ticket only once" do
      company = create(:company)
      user = create(:user, company: company)
      ticket = described_class.issue!(user: user, company_id: company.id)

      expect(described_class.consume(ticket)).to include("user_id" => user.id, "company_id" => company.id)
      expect(described_class.consume(ticket)).to be_nil
    end
  end
end
