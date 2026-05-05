# frozen_string_literal: true

module TimeTracking
  class OvertimeCalculator
    WEEKLY_THRESHOLD = 40.0

    def initialize(period_start:, period_end:)
      @period_start = period_start.to_date
      @period_end = period_end.to_date
    end

    def split_days(days)
      rows = normalize_days(days)
      result = { regular_hours: 0.0, overtime_hours: 0.0, total_hours: 0.0, days: [] }

      rows.group_by { |row| week_start(row[:date]) }.each_value do |week_rows|
        cumulative = 0.0
        week_rows.sort_by { |row| row[:date] }.each do |row|
          hours = row[:hours]
          regular = [ [ WEEKLY_THRESHOLD - cumulative, 0.0 ].max, hours ].min
          overtime = [ hours - regular, 0.0 ].max
          cumulative += hours

          next unless row[:date].between?(@period_start, @period_end)

          result[:regular_hours] += regular
          result[:overtime_hours] += overtime
          result[:total_hours] += hours
          result[:days] << row.merge(regular_hours: round(regular), overtime_hours: round(overtime))
        end
      end

      result[:regular_hours] = round(result[:regular_hours])
      result[:overtime_hours] = round(result[:overtime_hours])
      result[:total_hours] = round(result[:total_hours])
      result
    end

    def self.fetch_start_for(date)
      date.to_date.beginning_of_week(:sunday)
    end

    def self.fetch_end_for(date)
      date.to_date.end_of_week(:sunday)
    end

    private

    def normalize_days(days)
      Array(days).map do |day|
        {
          date: Date.parse(day["work_date"].to_s),
          hours: day["hours"].to_f,
          entry_ids: Array(day["entry_ids"]),
          categories: Array(day["categories"])
        }
      end
    end

    def week_start(date)
      date.beginning_of_week(:sunday)
    end

    def round(value)
      BigDecimal(value.to_s).round(2).to_f
    end
  end
end
