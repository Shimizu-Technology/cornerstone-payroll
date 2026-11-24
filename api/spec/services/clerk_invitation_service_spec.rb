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

  it "revokes each active Clerk session for a user and reports a refused revocation" do
    stub_request(:get, "https://api.clerk.com/v1/sessions")
      .with(query: { user_id: "user_closed", status: "active", limit: "100" })
      .to_return(status: 200, body: [ { id: "sess_one" }, { id: "sess_two" }, { id: "not-a-session" } ].to_json)
    one = stub_request(:post, "https://api.clerk.com/v1/sessions/sess_one/revoke").to_return(status: 200, body: "{}")
    two = stub_request(:post, "https://api.clerk.com/v1/sessions/sess_two/revoke").to_return(status: 200, body: "{}")

    expect(described_class.new.revoke_user_sessions("user_closed")).to eq(success: true, revoked: 2)
    expect([ one, two ]).to all(have_been_requested.once)

    stub_request(:post, "https://api.clerk.com/v1/sessions/sess_two/revoke").to_return(status: 500, body: "{}")
    expect(described_class.new.revoke_user_sessions("user_closed")).to include(success: false, revoked: 1)
    expect(described_class.new.revoke_user_sessions("../users")).to include(success: false)
  end

  it "ends only sessions created at or before a cutoff, and any without a creation time" do
    cutoff = Time.utc(2026, 11, 20, 12, 0, 0)
    stub_request(:get, "https://api.clerk.com/v1/sessions")
      .with(query: { user_id: "user_back", status: "active", limit: "100" })
      .to_return(status: 200, body: [
        { id: "sess_before", created_at: (cutoff.to_f * 1000).to_i - 1 },
        { id: "sess_at", created_at: (cutoff.to_f * 1000).to_i },
        { id: "sess_after", created_at: (cutoff.to_f * 1000).to_i + 60_000 },
        { id: "sess_unknown" }
      ].to_json)
    revoked = %w[sess_before sess_at sess_unknown].map do |id|
      stub_request(:post, "https://api.clerk.com/v1/sessions/#{id}/revoke").to_return(status: 200, body: "{}")
    end
    kept = stub_request(:post, "https://api.clerk.com/v1/sessions/sess_after/revoke")

    expect(described_class.new.revoke_user_sessions("user_back", created_before: cutoff)).to eq(success: true, revoked: 3)
    expect(revoked).to all(have_been_requested.once)
    expect(kept).not_to have_been_requested
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

  it "reports a definite no-match only after all filters answer successfully" do
    endpoint = "https://api.clerk.com/v1/invitations"
    query = { query: "inv_missing", limit: "10" }
    stub_request(:get, endpoint).with(query: query).to_return(status: 200, body: "[]")
    stub_request(:get, endpoint).with(query: query.merge(status: "revoked")).to_return(status: 200, body: '{"data":[]}')
    expired = stub_request(:get, endpoint).with(query: query.merge(status: "expired")).to_return(status: 200, body: "[]")

    expect(described_class.new.invitation_status("inv_missing")).to eq(:not_found)
    expect(expired).to have_been_requested
  end

  it "keeps a lookup failure distinct from a definite no-match" do
    endpoint = "https://api.clerk.com/v1/invitations"
    query = { query: "inv_unknown", limit: "10" }
    stub_request(:get, endpoint).with(query: query).to_return(status: 200, body: "[]")
    stub_request(:get, endpoint).with(query: query.merge(status: "revoked")).to_return(status: 200, body: "[]")
    stub_request(:get, endpoint).with(query: query.merge(status: "expired")).to_return(status: 503)

    expect(described_class.new.invitation_status("inv_unknown")).to be_nil
  end

  [ true, false ].each do |included_by_default|
    it "finds expired invitations when the default list #{included_by_default ? 'includes' : 'omits'} them" do
      endpoint = "https://api.clerk.com/v1/invitations"
      query = { query: "inv_expired", limit: "10" }
      expired = [ { id: "inv_expired", status: "expired" } ].to_json
      stub_request(:get, endpoint).with(query: query).to_return(status: 200, body: included_by_default ? expired : "[]")
      unless included_by_default
        stub_request(:get, endpoint).with(query: query.merge(status: "revoked")).to_return(status: 200, body: "[]")
        stub_request(:get, endpoint).with(query: query.merge(status: "expired")).to_return(status: 200, body: expired)
      end

      expect(described_class.new.invitation_status("inv_expired")).to eq("expired")
    end
  end

  it "checks every page of an ID query before declaring an invitation missing" do
    endpoint = "https://api.clerk.com/v1/invitations"
    query = { query: "inv_exact", limit: "10" }
    stub_request(:get, endpoint).with(query: query)
      .to_return(status: 200, body: { total_count: 11, data: Array.new(10) { |i| { id: "inv_exact#{i}" } } }.to_json)
    stub_request(:get, endpoint).with(query: query.merge(offset: "10"))
      .to_return(status: 200, body: { total_count: 11, data: [ { id: "inv_exact", status: "accepted" } ] }.to_json)

    expect(described_class.new.invitation_status("inv_exact")).to eq("accepted")
  end

  it "fails the lookup when more pages remain at the pagination cap" do
    endpoint = "https://api.clerk.com/v1/invitations"
    query = { query: "inv_exact", limit: "10" }
    page = { total_count: 101, data: Array.new(10) { |i| { id: "inv_exact#{i}" } } }.to_json
    requests = (0...100).step(10).map do |offset|
      page_query = offset.zero? ? query : query.merge(offset: offset.to_s)
      stub_request(:get, endpoint).with(query: page_query).to_return(status: 200, body: page)
    end

    expect(described_class.new.invitation_status("inv_exact")).to be_nil
    requests.each { |request| expect(request).to have_been_requested.once }
  end

  it "exposes verified addresses separately from the primary address and display name" do
    stub_request(:get, "https://api.clerk.com/v1/users/user_account")
      .to_return(status: 200, body: {
        id: "user_account", first_name: "Sample", last_name: "Recipient", primary_email_address_id: "id_primary",
        email_addresses: [
          { id: "id_primary", email_address: "unverified@example.test", verification: { status: "unverified" } },
          { id: "id_verified", email_address: "verified@example.test", verification: { status: "verified" } },
          { id: "id_missing", email_address: "missing@example.test", verification: nil }
        ]
      }.to_json)

    expect(described_class.new.recovery_account("user_account")).to eq(id: "user_account", name: "Sample Recipient",
      verified_emails: [ "verified@example.test" ], primary_email: "unverified@example.test")
  end

  it "requires the Clerk Backend API response to identify the requested subject" do
    stub_request(:get, "https://api.clerk.com/v1/users/user_requested")
      .to_return(status: 200, body: { id: "user_different" }.to_json)

    expect(described_class.new.fetch_user("user_requested")).to be_nil
  end
end
