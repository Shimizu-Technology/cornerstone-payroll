# frozen_string_literal: true

require "rails_helper"

RSpec.describe PriorProviderHistory::Discovery do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 11, 2, 2)) { example.run } }

  it "suggests past calculated runs only before any live commitment" do
    company, _actor, _employees, runs, = history_fixture(period_count: 1)
    expect(described_class.available?(company)).to be(true)
    expect(described_class.available?(company, period: runs.first)).to be(true)
    runs.first.update_columns(committed_at: Time.current)
    expect(described_class.available?(company)).to be(false)
    runs.first.update_columns(committed_at: nil, pay_date: Date.current)
    expect(described_class.available?(company)).to be(false)
    runs.first.update_columns(pay_date: Date.current - 1, parallel_run: true)
    expect(described_class.available?(company)).to be(false)
  end
end
