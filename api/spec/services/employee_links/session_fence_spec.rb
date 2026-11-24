# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeLinks::SessionFence do
  include ActiveSupport::Testing::TimeHelpers

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

  describe "the clock-skew allowance" do
    let(:allowance) { described_class::SESSION_SKEW_ALLOWANCE }

    def fenced_at?(created_at, sid)
      allow(clerk).to receive(:fetch_session).with(sid).and_return(session(created_at, id: sid))
      described_class.fenced?(login, payload.merge("sid" => sid), clerk: clerk)
    end

    it "is five minutes" do
      expect(allowance).to eq(5.minutes)
      expect(described_class.cutoff(closed_at)).to eq(closed_at + 5.minutes)
    end

    it "refuses a session stamped up to the allowance after the closure (Clerk's clock ahead)" do
      expect(fenced_at?(closed_at + 1.minute, "sess_ahead_a")).to be(true)
      expect(fenced_at?(closed_at + allowance, "sess_ahead_cutoff")).to be(true)
    end

    it "refuses a session stamped before the closure (Clerk's clock behind)" do
      expect(fenced_at?(closed_at - 0.001, "sess_behind_a")).to be(true)
      expect(fenced_at?(closed_at - 4.minutes, "sess_behind_b")).to be(true)
    end

    it "allows a session stamped just past the cutoff" do
      expect(fenced_at?(closed_at + allowance + 0.001, "sess_after_cutoff")).to be(false)
      expect(fenced_at?(closed_at + 1.day, "sess_next_day")).to be(false)
    end
  end

  it "ignores the token's factor-verification ages" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at - 1.hour))

    expect(described_class.fenced?(login, payload.merge("fva" => [ 0, 0 ], "iat" => Time.current.to_i), clerk: clerk)).to be(true)
  end

  it "fails closed when Clerk can't be read, the sid is malformed, or the session is someone else's" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true)

    Rails.cache.clear
    allow(clerk).to receive(:fetch_session).with("sess_now").and_raise(Timeout::Error)
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true)
    expect(clerk).to have_received(:fetch_session).twice

    allow(clerk).to receive(:fetch_session).with("sess_other")
      .and_return(session(closed_at + 1.hour, id: "sess_other", user_id: "user_someone"))
    expect(described_class.fenced?(login, payload.merge("sid" => "sess_other"), clerk: clerk)).to be(true)

    expect(described_class.fenced?(login, payload.merge("sid" => "../users"), clerk: clerk)).to be(true)
    expect(described_class.fenced?(login, payload.except("sid"), clerk: clerk)).to be(true)
  end

  it "reads each session's creation time from Clerk once, and only for that session's user" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at + 10.minutes))

    2.times { expect(described_class.fenced?(login, payload, clerk: clerk)).to be(false) }
    expect(clerk).to have_received(:fetch_session).once

    # A cached time is never lent to a token for another user.
    other = build(:user, role: :portal_employee, clerk_id: "user_other", deactivated_at: closed_at)
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)
    expect(described_class.fenced?(other, payload.merge("sub" => "user_other"), clerk: clerk)).to be(true)
  end

  it "remembers a failed lookup for about 30 seconds, staying refused, then asks Clerk again" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)

    freeze_time do
      3.times { expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true) }
      expect(clerk).to have_received(:fetch_session).once
      expect(described_class::NEGATIVE_CACHE_TTL).to eq(30.seconds)

      # Only failures are short-lived: the later success is cached for good.
      travel 31.seconds
      allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at + 1.hour))
      2.times { expect(described_class.fenced?(login, payload, clerk: clerk)).to be(false) }
      expect(clerk).to have_received(:fetch_session).twice
    end
  end

  it "keeps one user's failed lookup from refusing another user's lookup of the same sid" do
    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(nil)
    expect(described_class.fenced?(login, payload, clerk: clerk)).to be(true)

    allow(clerk).to receive(:fetch_session).with("sess_now").and_return(session(closed_at + 1.hour, user_id: "user_other"))
    other = build(:user, role: :portal_employee, clerk_id: "user_other", deactivated_at: closed_at)
    expect(described_class.fenced?(other, payload.merge("sub" => "user_other"), clerk: clerk)).to be(false)
  end
end
