# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeLinks::SessionFence do
  let(:clerk) { instance_double(ClerkInvitationService) }
  let(:closed_at) { Time.zone.parse("2026-11-20T02:00:00.123456Z") }
  let(:login) { build(:user, role: :portal_employee, clerk_id: "user_riley", deactivated_at: closed_at) }
  let(:payload) { { "sub" => "user_riley", "sid" => "sess_now" } }

  def session(created_at, id: "sess_now", user_id: "user_riley")
    { "id" => id, "user_id" => user_id, "status" => "active", "created_at" => (created_at.to_r * 1000).floor }
  end

  around do |example|
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = previous
  end

  it "never asks Clerk about a login that was never closed" do
    allow(clerk).to receive(:fetch_session)
    login.deactivated_at = nil

    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(false)
    expect(clerk).not_to have_received(:fetch_session)
  end

  it "refuses a session Clerk created at or before the closure, and allows one created after" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at + 0.001))
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(false)

    allow(clerk).to receive(:fetch_session).with("sess_then").and_return(session(closed_at, id: "sess_then"))
    expect(described_class.fenced?(login, payload.merge("sid" => "sess_then"), clerk: clerk)).to be(true)
  end

  it "ignores the token's factor-verification ages" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at - 1.hour))

    expect(described_class.fenced?(login, payload.merge("fva" => [ 0, 0 ], "iat" => Time.current.to_i), clerk: clerk)).to be(true)
  end

  it "fails closed when Clerk can't be read, the sid is malformed, or the session is someone else's" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true)

    allow(clerk).to receive(:fetch_session).with("sess_now").and_raise(Timeout::Error)
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true)

    allow(clerk).to receive(:fetch_session).with("sess_other")
      .and_return(session(closed_at + 1.hour, id: "sess_other", user_id: "user_someone"))
    expect(described_class.fenced?(login, payload.merge("sid" => "sess_other"), clerk: clerk)).to be(true)

    expect(described_class.fenced?(login, payload.merge("sid" => "../users"), clerk: clerk)).to be(true)
    expect(described_class.fenced?(login, payload.except("sid"), clerk: clerk)).to be(true)
  end

  it "reads each session's creation time from Clerk once, and only for that session's user" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at + 1.minute))

    2.times { expect(described_class.fenced?(login, payload, clerk: clerk)).to be(false) }
    expect(clerk).to have_received(:fetch_session).once

    # A cached time is never lent to a token for another user.
    other = build(:user, role: :portal_employee, clerk_id: "user_other", deactivated_at: closed_at)
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)
    expect(described_class.fenced?(other, payload.merge("sub" => "user_other"), clerk: clerk)).to be(true)
  end
end
