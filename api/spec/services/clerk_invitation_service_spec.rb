# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe ClerkInvitationService do
  around do |example|
    previous = ENV["CLERK_SECRET_KEY"]
    ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
    example.run
  ensure
    ENV["CLERK_SECRET_KEY"] = previous
  end

  it "reads the exact invitation ID from Clerk's list endpoint" do
    stub_request(:get, "https://api.clerk.com/v1/invitations")
      .with(query: { query: "inv_exact", limit: "10" }, headers: { "Authorization" => "Bearer sk_test_synthetic" })
      .to_return(status: 200, body: { data: [ { id: "inv_exact_other", status: "pending" },
        { id: "inv_exact", status: "accepted" } ] }.to_json)

    expect(described_class.new.invitation_status("inv_exact")).to eq("accepted")
  end

  it "finds revoked invitations using the revoked status filter" do
    endpoint = "https://api.clerk.com/v1/invitations"
    query = { query: "inv_closed", limit: "10" }
    stub_request(:get, endpoint).with(query: query).to_return(status: 200, body: "[]")
    stub_request(:get, endpoint).with(query: query.merge(status: "revoked"))
      .to_return(status: 200, body: [ { id: "inv_closed", status: "revoked" } ].to_json)

    expect(described_class.new.invitation_status("inv_closed")).to eq("revoked")
  end

  it "requires the Clerk Backend API response to identify the requested subject" do
    stub_request(:get, "https://api.clerk.com/v1/users/user_requested")
      .to_return(status: 200, body: { id: "user_different" }.to_json)

    expect(described_class.new.fetch_user("user_requested")).to be_nil
  end
end
