# frozen_string_literal: true

require "rails_helper"

RSpec.describe CableTicketService do
  it "issues short-lived one-time tickets for ActionCable connections" do
    cache = ActiveSupport::Cache::MemoryStore.new
    company = create(:company)
    user = create(:user, company: company)

    allow(Rails).to receive(:cache).and_return(cache)

    ticket = described_class.issue!(user: user, company_id: company.id)
    payload = described_class.consume(ticket)

    expect(payload).to include("user_id" => user.id, "company_id" => company.id)
    expect(described_class.consume(ticket)).to be_nil
  end
end
