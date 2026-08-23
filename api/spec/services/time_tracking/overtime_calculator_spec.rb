# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::OvertimeCalculator do
  describe "#split_days" do
    it "uses surrounding workweek hours to allocate overtime inside semi-monthly periods" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 15),
        workweek_start_weekday: 0
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

    it "uses the configured weekday instead of a hard-coded Sunday workweek" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 24),
        period_end: Date.new(2026, 5, 24),
        workweek_start_weekday: 1
      )
      days = (Date.new(2026, 5, 18)..Date.new(2026, 5, 22)).map do |date|
        { "work_date" => date.iso8601, "hours" => 8 }
      end
      days << { "work_date" => "2026-05-24", "hours" => 8 }

      result = calculator.split_days(days)

      expect(result[:regular_hours]).to eq(0.0)
      expect(result[:overtime_hours]).to eq(8.0)
    end

    it "uses total_hours when a v1 day omits the hours alias" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 18),
        workweek_start_weekday: 1
      )

      result = calculator.split_days([ { "work_date" => "2026-05-18", "total_hours" => 8 } ])

      expect(result).to include(regular_hours: 8.0, overtime_hours: 0.0, total_hours: 8.0)
    end

    it "does not let source category splits override Payroll's day-level overtime result" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31),
        workweek_start_weekday: 1
      )

      result = calculator.split_days([
        {
          "work_date" => "2026-05-18",
          "hours" => 20,
          "categories" => [
            { "source_category_id" => "flight", "name" => "Flight", "total_hours" => 15, "regular_hours" => 12, "overtime_hours" => 3 },
            { "source_category_id" => "ground", "name" => "Ground", "total_hours" => 5, "regular_hours" => 5, "overtime_hours" => 0 }
          ]
        }
      ])

      expect(result[:regular_hours]).to eq(20.0)
      expect(result[:overtime_hours]).to eq(0.0)
      expect(result.dig(:days, 0, :categories)).to contain_exactly(
        include(source_category_id: "flight", regular_hours: 15.0, overtime_hours: 0.0),
        include(source_category_id: "ground", regular_hours: 5.0, overtime_hours: 0.0)
      )
    end

    it "blocks ambiguous category allocation when a day crosses Payroll's overtime threshold" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31),
        workweek_start_weekday: 1
      )

      prior_days = (Date.new(2026, 5, 18)..Date.new(2026, 5, 22)).map do |date|
        { "work_date" => date.iso8601, "hours" => 7 }
      end

      expect do
        calculator.split_days(prior_days + [
          {
            "work_date" => "2026-05-23",
            "hours" => 10,
            "categories" => [
              { "source_category_id" => "flight", "name" => "Flight", "total_hours" => 6 },
              { "source_category_id" => "ground", "name" => "Ground", "total_hours" => 4 }
            ]
          }
        ])
      end.to raise_error(TimeTracking::OvertimeCalculator::AllocationError, /must provide category regular\/overtime splits/)
    end

    it "uses reconciled source splits only to allocate Payroll's category totals" do
      calculator = described_class.new(
        period_start: Date.new(2026, 5, 18),
        period_end: Date.new(2026, 5, 31),
        workweek_start_weekday: 1
      )

      prior_days = (Date.new(2026, 5, 18)..Date.new(2026, 5, 22)).map do |date|
        { "work_date" => date.iso8601, "hours" => 7 }
      end

      result = calculator.split_days(prior_days + [
        {
          "work_date" => "2026-05-23",
          "hours" => 10,
          "categories" => [
            { "source_category_id" => "flight", "name" => "Flight", "total_hours" => 6, "regular_hours" => 5, "overtime_hours" => 1 },
            { "source_category_id" => "ground", "name" => "Ground", "total_hours" => 4, "regular_hours" => 0, "overtime_hours" => 4 }
          ]
        }
      ])

      expect(result[:regular_hours]).to eq(40.0)
      expect(result[:overtime_hours]).to eq(5.0)
      expect(result.dig(:days, 5, :categories)).to contain_exactly(
        include(source_category_id: "flight", regular_hours: 5.0, overtime_hours: 1.0),
        include(source_category_id: "ground", regular_hours: 0.0, overtime_hours: 4.0)
      )
    end
  end

  describe ".fetch_start_for and .fetch_end_for" do
    it "returns the complete configured workweek around a date" do
      date = Date.new(2026, 5, 24)

      expect(described_class.fetch_start_for(date, workweek_start_weekday: 1)).to eq(Date.new(2026, 5, 18))
      expect(described_class.fetch_end_for(date, workweek_start_weekday: 1)).to eq(Date.new(2026, 5, 24))
    end
  end
end
