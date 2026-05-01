# frozen_string_literal: true

require "rails_helper"

RSpec.describe PunchEntry, type: :model do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:timecard) do
    Timecard.create!(
      company: company,
      pay_period: pay_period,
      employee_name: "Amanda Matas",
      period_start: pay_period.start_date,
      period_end: pay_period.end_date
    )
  end

  it "calculates a single visible in/out pair even when it is in the first out column" do
    entry = described_class.create!(
      timecard: timecard,
      card_day: 26,
      date: Date.new(2026, 4, 26),
      clock_in: "08:25",
      lunch_out: "12:02"
    )

    expect(entry.hours_worked).to eq(3.62)
    expect(entry.calculated_hours).to eq(3.62)
    expect(entry).not_to be_missing_core_punch
  end

  it "clears stale hours when no complete pair remains" do
    entry = described_class.create!(
      timecard: timecard,
      card_day: 26,
      date: Date.new(2026, 4, 26),
      clock_in: "08:25",
      lunch_out: "12:02"
    )
    entry.update_column(:hours_worked, 10.77)

    entry.update!(lunch_out: nil)

    expect(entry.reload.hours_worked).to be_nil
  end

  it "falls back to clock-in through clock-out when one lunch punch is missing" do
    entry = described_class.create!(
      timecard: timecard,
      card_day: 27,
      date: Date.new(2026, 4, 27),
      clock_in: "08:00",
      lunch_out: "12:00",
      clock_out: "17:00"
    )

    expect(entry.hours_worked).to eq(9.0)
    expect(entry).to be_missing_core_punch
  end

  it "flags a trailing third in punch without a matching out punch" do
    entry = described_class.create!(
      timecard: timecard,
      card_day: 28,
      date: Date.new(2026, 4, 28),
      clock_in: "08:00",
      in3: "13:00"
    )

    expect(entry.hours_worked).to be_nil
    expect(entry).to be_missing_core_punch
    expect(entry).to be_needs_attention
  end
end
