require "rails_helper"

RSpec.describe User, type: :model do
  let(:user) { create(:user) }
  let(:time) { Time.zone.parse("2026-07-16 09:00:00") }

  it "records a new authenticated session as a login" do
    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time)).to be(true)

    expect(user.reload.last_login_at).to eq(time)
    expect(user.last_active_at).to eq(time)
    expect(user.last_session_id_digest).to eq(Digest::SHA256.hexdigest("session-one"))
  end

  it "throttles activity writes within the same session" do
    user.record_authenticated_activity!(session_id: "session-one", occurred_at: time)

    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time + 2.minutes)).to be(false)
    expect(user.reload.last_active_at).to eq(time)

    expect(user.record_authenticated_activity!(session_id: "session-one", occurred_at: time + 6.minutes)).to be(false)
    expect(user.reload.last_active_at).to eq(time + 6.minutes)
    expect(user.last_login_at).to eq(time)
  end
end
