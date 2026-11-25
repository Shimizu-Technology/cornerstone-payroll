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

  describe "#revoke_user_sessions" do
    let(:sessions_url) { "https://api.clerk.com/v1/sessions" }

    def session_page(subject, sessions, offset: nil)
      query = { user_id: subject, status: "active", limit: "100" }
      query[:offset] = offset.to_s if offset
      stub_request(:get, sessions_url).with(query: query)
    end

    def revoke_stub(id, status: 200)
      stub_request(:post, "#{sessions_url}/#{id}/revoke").to_return(status: status, body: "{}")
    end

    it "lists every page before revoking, then confirms nothing targeted is left" do
      first = Array.new(100) { |index| { id: "sess_a#{index}" } }
      session_page("user_closed", first).to_return(status: 200, body: first.to_json).then
        .to_return(status: 200, body: "[]")
      session_page("user_closed", [], offset: 100).to_return(status: 200, body: [ { id: "sess_old" }, { id: "not-a-session" } ].to_json)
      stub_request(:post, %r{\A#{sessions_url}/sess_[a-z0-9]+/revoke\z}).to_return(status: 200, body: "{}")

      expect(described_class.new.revoke_user_sessions("user_closed")).to eq(success: true, revoked: 101)
      expect(a_request(:post, "#{sessions_url}/sess_old/revoke")).to have_been_made.once
      expect(described_class.new.revoke_user_sessions("../users")).to include(success: false)
    end

    it "counts an already-ended or missing session as revoked" do
      session_page("user_closed", []).to_return(status: 200, body: [ { id: "sess_gone" }, { id: "sess_ended" } ].to_json)
        .then.to_return(status: 200, body: "[]")
      revoke_stub("sess_gone", status: 404)
      revoke_stub("sess_ended", status: 400)
      stub_request(:get, "#{sessions_url}/sess_ended").to_return(status: 200, body: { id: "sess_ended", status: "revoked" }.to_json)

      expect(described_class.new.revoke_user_sessions("user_closed")).to eq(success: true, revoked: 2)
    end

    it "fails when a revocation is refused or a session is still active afterwards, so the job retries" do
      session_page("user_closed", []).to_return(status: 200, body: [ { id: "sess_one" } ].to_json)
      revoke_stub("sess_one", status: 500)
      stub_request(:get, "#{sessions_url}/sess_one").to_return(status: 200, body: { id: "sess_one", status: "active" }.to_json)
      expect(described_class.new.revoke_user_sessions("user_closed")).to include(success: false, revoked: 0)

      revoke_stub("sess_one")
      expect(described_class.new.revoke_user_sessions("user_closed")).to include(success: false, revoked: 1)
    end

    it "stops at the page cap, revokes what it listed, logs loudly and reports failure" do
      stub_const("#{described_class}::SESSION_PAGE_CAP", 2)
      full = ->(prefix) { Array.new(100) { |index| { id: "sess_#{prefix}#{index}" } }.to_json }
      session_page("user_busy", []).to_return(status: 200, body: full.call("a"))
      session_page("user_busy", [], offset: 100).to_return(status: 200, body: full.call("b"))
      stub_request(:post, %r{\A#{sessions_url}/sess_[a-z0-9]+/revoke\z}).to_return(status: 200, body: "{}")
      allow(Rails.logger).to receive(:error)

      expect(described_class.new.revoke_user_sessions("user_busy")).to include(success: false, revoked: 200)
      expect(Rails.logger).to have_received(:error).with(/SESSION PAGE CAP HIT/)
    end

    it "reports failure when only the confirming pass hits the page cap" do
      stub_const("#{described_class}::SESSION_PAGE_CAP", 2)
      cutoff = Time.utc(2026, 11, 20, 12, 0, 0)
      later = (cutoff.to_f * 1000).to_i + 60_000
      full = ->(prefix) { Array.new(100) { |index| { id: "sess_#{prefix}#{index}", created_at: later } }.to_json }
      # The first pass lists one page and ends its one targeted session; the
      # confirming pass then finds more pages than the cap allows.
      session_page("user_busy", []).to_return(status: 200, body: [ { id: "sess_old", created_at: later - 120_000 } ].to_json)
        .then.to_return(status: 200, body: full.call("a"))
      session_page("user_busy", [], offset: 100).to_return(status: 200, body: full.call("b"))
      revoke = revoke_stub("sess_old")
      allow(Rails.logger).to receive(:error)

      expect(described_class.new.revoke_user_sessions("user_busy", created_before: cutoff))
        .to eq(success: false, error: "Too many Clerk sessions to confirm in one pass", revoked: 1)
      expect(revoke).to have_been_requested.once
      expect(Rails.logger).to have_received(:error).with(/SESSION PAGE CAP HIT/)
    end

    it "ends only sessions created at or before a cutoff, and any without a creation time" do
      cutoff = Time.utc(2026, 11, 20, 12, 0, 0)
      millis = (cutoff.to_f * 1000).to_i
      after = { id: "sess_after", created_at: millis + 60_000 }
      session_page("user_back", []).to_return(status: 200, body: [
        { id: "sess_before", created_at: millis - 1 }, { id: "sess_at", created_at: millis }, after, { id: "sess_unknown" }
      ].to_json).then.to_return(status: 200, body: [ after ].to_json)
      revoked = %w[sess_before sess_at sess_unknown].map { |id| revoke_stub(id) }
      kept = revoke_stub("sess_after")

      expect(described_class.new.revoke_user_sessions("user_back", created_before: cutoff)).to eq(success: true, revoked: 3)
      expect(revoked).to all(have_been_requested.once)
      expect(kept).not_to have_been_requested
    end
  end

  it "reads one session by its ID, and nothing for a malformed ID" do
    stub_request(:get, "https://api.clerk.com/v1/sessions/sess_one")
      .to_return(status: 200, body: { id: "sess_one", user_id: "user_a", created_at: 1_700_000_000_000 }.to_json)
    expect(described_class.new.fetch_session("sess_one")).to include("user_id" => "user_a", "created_at" => 1_700_000_000_000)
    expect(described_class.new.fetch_session("../users")).to be_nil
  end

  it "finds Clerk users by address and deletes one, counting an already-deleted user as deleted" do
    stub_request(:get, "https://api.clerk.com/v1/users").with(query: { email_address: "new@example.test", limit: "100" })
      .to_return(status: 200, body: [ { id: "user_made" } ].to_json)
    expect(described_class.new.users_with_email("new@example.test")).to eq([ { "id" => "user_made" } ])

    stub_request(:delete, "https://api.clerk.com/v1/users/user_made").to_return(status: 200, body: "{}")
    stub_request(:delete, "https://api.clerk.com/v1/users/user_gone").to_return(status: 404, body: "{}")
    stub_request(:delete, "https://api.clerk.com/v1/users/user_stuck").to_return(status: 500, body: "{}")
    expect(described_class.new.delete_user("user_made", email: "new@example.test")).to eq(success: true)
    expect(described_class.new.delete_user("user_gone", email: "new@example.test")).to eq(success: true)
    expect(described_class.new.delete_user("user_stuck", email: "new@example.test")).to include(success: false)
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

  describe "#create_invitation logging" do
    let(:address) { "reviewer+manager@demo-mail.example" }
    let(:logged) { [] }

    before do
      allow(StagingOutboundPolicy).to receive(:clerk_target!)
      allow(Rails.logger).to receive(:info) { |line| logged << line }
      allow(Rails.logger).to receive(:error) { |line| logged << line }
    end

    it "logs the domain, never the address, on success" do
      stub_request(:post, "https://api.clerk.com/v1/invitations").to_return(status: 200, body: { id: "inv_1", status: "pending" }.to_json)
      expect(described_class.new.create_invitation(email: address)).to include(success: true, invitation_id: "inv_1")
      expect(logged.join).to include("***@demo-mail.example")
      expect(logged.join).not_to include("reviewer")
    end

    it "logs a stable code instead of Clerk's text on failure, and returns the code" do
      body = { errors: [ { code: "form_identifier_exists", long_message: "#{address} is taken" } ] }
      stub_request(:post, "https://api.clerk.com/v1/invitations").to_return(status: 422, body: body.to_json)
      result = described_class.new.create_invitation(email: address)
      expect(result).to include(success: false, status_code: 422, error_code: "form_identifier_exists")
      expect(logged.join).to include("code=form_identifier_exists")
      expect(logged.join).not_to include("reviewer")
    end
  end
end
