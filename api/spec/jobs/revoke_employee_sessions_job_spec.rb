# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# The job and EmployeeLinks::SessionFence share one cutoff: the closure time
# plus SESSION_SKEW_ALLOWANCE, so a session either side refuses is one the
# other ends, whichever way Clerk's clock is off.
RSpec.describe RevokeEmployeeSessionsJob do
  let(:sessions_url) { "https://api.clerk.com/v1/sessions" }
  let(:closed_at) { Time.zone.parse("2026-11-20T02:00:00.123456Z") }
  let(:allowance) { EmployeeLinks::SessionFence::SESSION_SKEW_ALLOWANCE }
  let(:worker) do
    create(:user, role: :portal_employee, clerk_id: "user_riley", invitation_status: "accepted", active: false,
      deactivated_at: closed_at, deactivation_reason: "last_employee_link_closed")
  end

  around do |example|
    previous = ENV["CLERK_SECRET_KEY"]
    ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
    example.run
  ensure
    ENV["CLERK_SECRET_KEY"] = previous
  end

  def millis(time)
    (time.to_r * 1000).floor
  end

  it "ends sessions up to the allowance after the closure in either skew direction, and keeps later ones" do
    ended = {
      "sess_behind" => closed_at - 2.minutes, # Clerk's clock behind the database
      "sess_ahead" => closed_at + 4.minutes, # Clerk's clock ahead, within the allowance
      "sess_at_cutoff" => closed_at + allowance
    }
    kept = { "sess_after" => closed_at + allowance + 0.001 }
    listing = ended.merge(kept).map { |id, created| { id: id, user_id: "user_riley", created_at: millis(created) } }
    stub_request(:get, sessions_url).with(query: { user_id: "user_riley", status: "active", limit: "100" })
      .to_return(status: 200, body: listing.to_json).then
      .to_return(status: 200, body: listing.select { |session| kept.key?(session[:id]) }.to_json)
    revokes = ended.keys.map { |id| stub_request(:post, "#{sessions_url}/#{id}/revoke").to_return(status: 200, body: "{}") }
    kept_revoke = stub_request(:post, "#{sessions_url}/sess_after/revoke").to_return(status: 200, body: "{}")

    described_class.perform_now(worker.id, closed_at.iso8601(6))

    expect(revokes).to all(have_been_requested.once)
    expect(kept_revoke).not_to have_been_requested

    # The fence draws the same line.
    clerk = instance_double(ClerkInvitationService)
    listing.each do |session|
      allow(clerk).to receive(:fetch_session).with(session[:id]).and_return(session.deep_stringify_keys.merge("status" => "active"))
    end
    fenced = listing.to_h do |session|
      [ session[:id], EmployeeLinks::SessionFence.fenced?(worker, { "sub" => "user_riley", "sid" => session[:id] }, clerk: clerk) ]
    end
    expect(fenced).to eq("sess_behind" => true, "sess_ahead" => true, "sess_at_cutoff" => true, "sess_after" => false)
  end
end
