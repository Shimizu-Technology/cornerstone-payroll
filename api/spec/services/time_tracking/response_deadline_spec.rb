# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Time tracking complete response deadline" do
  include CalendarStreamTransport

  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:external_id) { SecureRandom.uuid }

  before { stub_const("TimeTracking::Client::TOTAL_RESPONSE_TIMEOUT_SECONDS", 0.1) }

  [ :get, :put ].each do |method|
    it "aborts slow-drip #{method.upcase} consumption despite chunks arriving within the read timeout" do
      client, http, consumed = streamed_calendar_client(source, payload: {}, delay: 0.02)
      expect do
        if method == :get
          client.payroll_calendar_period(external_pay_period_id: external_id)
        else
          client.publish_payroll_calendar_period(external_pay_period_id: external_id, payload: {}, idempotency_key: SecureRandom.uuid)
        end
      end.to raise_error(TimeTracking::Client::Error, /Could not securely reach/)
      expect(consumed.length).to be_between(1, 19)
      expect(http.finished).to be(true)
      expect(http.request_count).to eq(1)
      expect(http.read_timeout).to eq(TimeTracking::Client::READ_TIMEOUT_SECONDS)
    end
  end

  it "also bounds waiting for response headers" do
    client, http, consumed = streamed_calendar_client(source, payload: {}, before_response: -> { sleep 0.3 })
    expect { client.payroll_calendar_period(external_pay_period_id: external_id) }
      .to raise_error(TimeTracking::Client::Error, /Could not securely reach/)
    expect(consumed).to be_empty
    expect(http.finished).to be(true)
  end

  it "accepts an ordinary unwrapped GET before the deadline" do
    payload = { "next_scheduled_cutoff_at" => nil }
    client, http = streamed_calendar_client(source, payload: payload)
    expect(client.payroll_calendar_period(external_pay_period_id: external_id)).to eq(payload)
    expect(http.finished).to be(true)
    expect(http.request_sent["X-Payroll-Shared-Secret"]).to eq(source.shared_secret)
  end
end
