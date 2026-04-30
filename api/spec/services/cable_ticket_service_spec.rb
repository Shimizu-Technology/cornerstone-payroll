# frozen_string_literal: true

require "rails_helper"

RSpec.describe CableTicketService do
  it "issues short-lived one-time tickets for ActionCable connections" do
    company = create(:company)
    user = create(:user, company: company)

    ticket = described_class.issue!(user: user, company_id: company.id)
    payload = described_class.consume(ticket)

    expect(payload).to include("user_id" => user.id, "company_id" => company.id)
    expect(described_class.consume(ticket)).to be_nil
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
