# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollReportingPeriod do
  it "builds a calendar-year pay-date period" do
    period = described_class.from_params({ year: "2026" })

    expect(period.range).to eq(Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
    expect(period.custom?).to be(false)
    expect(period.payload[:basis]).to eq("pay_date")
  end

  it "builds an exact custom range" do
    period = described_class.from_params({ start_date: "2026-02-03", end_date: "2026-03-07" })

    expect(period.range).to eq(Date.new(2026, 2, 3)..Date.new(2026, 3, 7))
    expect(period.custom?).to be(true)
    expect(period.filename_token).to eq("2026-02-03_to_2026-03-07")
  end

  it "builds an explicit all-history period without treating it as a custom range" do
    period = described_class.all_time

    expect(period.range).to eq(Date.new(1900, 1, 1)..Date.new(9999, 12, 31))
    expect(period.all_time?).to be(true)
    expect(period.custom?).to be(false)
    expect(period.label).to eq("All pay history")
    expect(period.filename_token).to eq("all_pay_history")
    expect(period.payload).to include(all_time: true, custom: false, year: nil)
  end

  it "rejects partial and invalid ranges" do
    expect { described_class.from_params({ start_date: "2026-01-01" }) }.to raise_error(ArgumentError, /both required/)
    expect { described_class.from_params({ start_date: "not-a-date", end_date: "2026-01-02" }) }.to raise_error(ArgumentError, /YYYY-MM-DD/)
    expect { described_class.from_params({ start_date: "2026-02-01", end_date: "2026-01-01" }) }.to raise_error(ArgumentError, /on or before/)
  end
end
