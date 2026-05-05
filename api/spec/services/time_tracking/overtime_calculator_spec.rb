# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::OvertimeCalculator do
  describe "#split_days" do
    it "uses surrounding week hours to allocate overtime inside semi-monthly periods" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 15)
      )

      days = [
        { "work_date" => "2026-04-27", "hours" => 10 },
        { "work_date" => "2026-04-28", "hours" => 10 },
        { "work_date" => "2026-04-29", "hours" => 10 },
        { "work_date" => "2026-04-30", "hours" => 10 },
        { "work_date" => "2026-05-01", "hours" => 8 },
        { "work_date" => "2026-05-02", "hours" => 8 }
      ]

      result = calculator.split_days(days)

      expect(result[:regular_hours]).to eq(0.0)
      expect(result[:overtime_hours]).to eq(16.0)
      expect(result[:total_hours]).to eq(16.0)
    end
  end
end
