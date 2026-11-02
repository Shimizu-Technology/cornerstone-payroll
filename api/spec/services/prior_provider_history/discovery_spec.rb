# frozen_string_literal: true

require "rails_helper"

RSpec.describe PriorProviderHistory::Discovery do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 11, 1, 16)) { example.run } }

  it "suggests past calculated runs only before any live commitment" do
    company, _actor, _employees, runs, = history_fixture(period_count: 1)
    expect(described_class.available?(company)).to be(true)
    expect(described_class.available?(company, period: runs.first)).to be(true)
    runs.first.update_columns(pay_date: Date.new(2026, 11, 1))
    expect(described_class.available?(company, period: runs.first)).to be(true)
    expect(described_class.candidates(company)).to include(runs.first)
    runs.first.update_columns(committed_at: Time.current)
    expect(described_class.available?(company)).to be(false)
    runs.first.update_columns(committed_at: nil, pay_date: PayrollBusinessClock.today)
    expect(described_class.available?(company)).to be(false)
    runs.first.update_columns(pay_date: PayrollBusinessClock.today - 1, parallel_run: true)
    expect(described_class.available?(company)).to be(false)
  end
  it "accepts the previous Guam business day's paid run in the plan before UTC midnight" do
    company, _actor, _employees, runs, payload = history_fixture(period_count: 1)
    runs.first.update!(pay_date: Date.new(2026, 11, 1))
    payload["takeover_on"] = "2026-11-02"
    payload["periods"].first["pay_date"] = "2026-11-01"
    payload["periods"].first["source_digest"] = PriorProviderHistory::SourceAdapter.digest(runs.first)
    plan = PriorProviderHistory::Plan.new(company: company, payload: payload).call
    expect(plan.errors).to be_empty
  end
end
