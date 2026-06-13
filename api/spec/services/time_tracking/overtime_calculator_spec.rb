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

    it "keeps unsplit category hours when another category has source-provided splits" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31)
      )

      result = calculator.split_days([
        {
          "work_date" => "2026-05-18",
          "hours" => 20,
          "categories" => [
            { "source_category_id" => "flight", "key" => "aire_flight", "name" => "Flight", "total_hours" => 8, "regular_hours" => 8, "overtime_hours" => 0 },
            { "source_category_id" => "ground", "key" => "aire_ground", "name" => "Ground", "total_hours" => 12 }
          ]
        }
      ])

      expect(result.dig(:days, 0, :categories)).to contain_exactly(
        include(source_category_id: "flight", regular_hours: 8.0, overtime_hours: 0.0, total_hours: 8.0),
        include(source_category_id: "ground", regular_hours: 12.0, overtime_hours: 0.0, total_hours: 12.0)
      )
    end

    it "does not cap unsplit category totals when source-provided splits exhaust the day pool" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31)
      )

      result = calculator.split_days([
        {
          "work_date" => "2026-05-18",
          "hours" => 20,
          "categories" => [
            { "source_category_id" => "flight", "key" => "aire_flight", "name" => "Flight", "total_hours" => 20, "regular_hours" => 20, "overtime_hours" => 0 },
            { "source_category_id" => "ground", "key" => "aire_ground", "name" => "Ground", "total_hours" => 5 }
          ]
        }
      ])

      expect(result.dig(:days, 0, :categories)).to contain_exactly(
        include(source_category_id: "flight", regular_hours: 20.0, overtime_hours: 0.0, total_hours: 20.0),
        include(source_category_id: "ground", regular_hours: 0.0, overtime_hours: 5.0, total_hours: 5.0)
      )
    end

    it "preserves source category regular and overtime splits" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31)
      )

      result = calculator.split_days([
        {
          "work_date" => "2026-05-18",
          "hours" => 20,
          "categories" => [
            { "source_category_id" => "flight", "key" => "aire_flight", "name" => "Flight", "regular_hours" => 12, "overtime_hours" => 3, "effective_rate_cents" => 7500 },
            { "source_category_id" => "ground", "key" => "aire_ground", "name" => "Ground", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 4500 }
          ]
        }
      ])

      expect(result.dig(:days, 0, :categories)).to contain_exactly(
        include(source_category_id: "flight", key: "aire_flight", name: "Flight", regular_hours: 12.0, overtime_hours: 3.0, total_hours: 15.0, effective_rate_cents: 7500),
        include(source_category_id: "ground", key: "aire_ground", name: "Ground", regular_hours: 5.0, overtime_hours: 0.0, total_hours: 5.0, effective_rate_cents: 4500)
      )
    end
  end
end
