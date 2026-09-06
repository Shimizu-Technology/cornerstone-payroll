# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::PeriodKey do
  it "uses the same stable payroll-period identity everywhere" do
    row = {
      period_start: Date.new(2024, 6, 14),
      period_end: Date.new(2024, 6, 27),
      pay_date: Date.new(2024, 7, 3),
      period_type: "regular"
    }

    expect(described_class.call(row)).to eq(
      Digest::SHA256.hexdigest("2024-06-14|2024-06-27|2024-07-03|regular")
    )
  end
end
