require "rails_helper"

RSpec.describe User, type: :model do
  let(:user) { create(:user) }
  let(:time) { Time.zone.parse("2026-07-16 09:00:00") }

  it "records a new authenticated session as a login" do
    expect(user.authenticated_activity_write_due?(session_id: "session-one", occurred_at: time)).to be(true)
    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time)).to be(true)

    expect(user.reload.last_login_at).to eq(time)
    expect(user.last_active_at).to eq(time)
    expect(user.last_session_id_digest).to eq(Digest::SHA256.hexdigest("session-one"))
    expect(user).not_to be_changed
  end

  it "throttles activity writes within the same session" do
    user.record_authenticated_activity!(session_id: "session-one", occurred_at: time)

    expect(user.authenticated_activity_write_due?(session_id: "session-one", occurred_at: time + 2.minutes)).to be(false)
    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time + 2.minutes)).to be(false)
    expect(user.reload.last_active_at).to eq(time)

    expect(user.authenticated_activity_write_due?(session_id: "session-one", occurred_at: time + 6.minutes)).to be(true)
    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time + 6.minutes)).to be(false)
    expect(user.reload.last_active_at).to eq(time + 6.minutes)
    expect(user.last_login_at).to eq(time)
  end

  it "recognizes a changed session even during the activity throttle window" do
    user.record_authenticated_activity!(session_id: "session-one", occurred_at: time)

    expect(user.authenticated_activity_write_due?(session_id: "session-two", occurred_at: time + 1.minute)).to be(true)
  end
end
