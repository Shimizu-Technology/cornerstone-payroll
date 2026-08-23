# frozen_string_literal: true

module TimeTracking
  class OvertimeCalculator
    class AllocationError < ArgumentError; end

    WEEKLY_THRESHOLD = 40.0
    RECONCILIATION_TOLERANCE = 0.01

    def initialize(period_start:, period_end:, workweek_start_weekday:)
      @period_start = period_start.to_date
      @period_end = period_end.to_date
      @workweek_start_weekday = Integer(workweek_start_weekday)
      raise ArgumentError, "workweek_start_weekday must be between 0 and 6" unless @workweek_start_weekday.between?(0, 6)
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

          regular = round(regular)
          overtime = round(overtime)
          category_splits = split_categories(
            row[:categories],
            regular_hours: regular,
            overtime_hours: overtime,
            work_date: row[:date]
          )
          regular = round(category_splits.sum { |category| category[:regular_hours].to_f }) if category_splits.present?
          overtime = round(category_splits.sum { |category| category[:overtime_hours].to_f }) if category_splits.present?
          total_hours = category_splits.present? ? round(category_splits.sum { |category| category[:total_hours].to_f }) : round(hours)

          result[:regular_hours] += regular
          result[:overtime_hours] += overtime
          result[:total_hours] += total_hours
          result[:days] << row.merge(
            hours: total_hours,
            total_hours: total_hours,
            regular_hours: regular,
            overtime_hours: overtime,
            categories: category_splits
          )
        end
      end

      result[:regular_hours] = round(result[:regular_hours])
      result[:overtime_hours] = round(result[:overtime_hours])
      result[:total_hours] = round(result[:total_hours])
      result
    end

    def self.fetch_start_for(date, workweek_start_weekday:)
      work_date = date.to_date
      work_date - ((work_date.wday - Integer(workweek_start_weekday)) % 7).days
    end

    def self.fetch_end_for(date, workweek_start_weekday:)
      fetch_start_for(date, workweek_start_weekday: workweek_start_weekday) + 6.days
    end

    private

    def normalize_days(days)
      Array(days).map do |day|
        categories = Array(day["categories"]).map { |category| normalize_category(category) }
        category_hours = categories.sum { |category| category[:total_hours].to_f }
        day_hours = day.key?("hours") ? day["hours"] : day["total_hours"]
        {
          date: Date.parse(day["work_date"].to_s),
          hours: day_hours.nil? ? category_hours : day_hours.to_f,
          entry_ids: Array(day["entry_ids"]),
          categories: categories
        }
      end
    end

    def normalize_category(category)
      category = category.to_h if category.respond_to?(:to_h)
      category ||= {}
      regular_present = category.key?("regular_hours") || category.key?(:regular_hours)
      overtime_present = category.key?("overtime_hours") || category.key?(:overtime_hours)
      explicit_total_hours = category["total_hours"] || category[:total_hours] || category["hours"] || category[:hours]
      regular_hours = regular_present ? (category["regular_hours"] || category[:regular_hours]).to_f : nil
      overtime_hours = overtime_present ? (category["overtime_hours"] || category[:overtime_hours]).to_f : nil
      total_hours = explicit_total_hours.present? ? explicit_total_hours.to_f : regular_hours.to_f + overtime_hours.to_f

      if regular_present && !overtime_present
        overtime_hours = [ total_hours - regular_hours.to_f, 0.0 ].max
      elsif overtime_present && !regular_present
        regular_hours = [ total_hours - overtime_hours.to_f, 0.0 ].max
      end

      {
        source_category_id: (category["source_category_id"] || category[:source_category_id]).to_s.presence,
        key: (category["key"] || category[:key]).to_s.presence,
        name: category["name"] || category[:name] || "Uncategorized",
        total_hours: total_hours,
        regular_hours: regular_hours,
        overtime_hours: overtime_hours,
        split_provided: regular_present || overtime_present,
        effective_rate_cents: category["effective_rate_cents"] || category[:effective_rate_cents],
        entry_ids: Array(category["entry_ids"] || category[:entry_ids])
      }
    end

    def split_categories(categories, regular_hours:, overtime_hours:, work_date:)
      return [] if categories.blank?

      return [ category_payload(categories.first, regular_hours, overtime_hours) ] if categories.one?
      return categories.map { |category| category_payload(category, category[:total_hours], 0.0) } if overtime_hours.zero?
      return categories.map { |category| category_payload(category, 0.0, category[:total_hours]) } if regular_hours.zero?

      unless categories.all? { |category| category[:split_provided] } &&
             reconciles?(categories.sum { |category| category[:regular_hours].to_f }, regular_hours) &&
             reconciles?(categories.sum { |category| category[:overtime_hours].to_f }, overtime_hours)
        raise AllocationError,
              "Multiple categories cross the overtime threshold on #{work_date}; " \
              "the source must provide category regular/overtime splits that reconcile with Payroll"
      end

      categories.map do |category|
        category_payload(category, category[:regular_hours], category[:overtime_hours])
      end
    end

    def category_payload(category, regular_hours, overtime_hours)
      total_hours = round(regular_hours.to_f + overtime_hours.to_f)
      {
        source_category_id: category[:source_category_id],
        key: category[:key],
        name: category[:name],
        hours: total_hours,
        total_hours: total_hours,
        regular_hours: round(regular_hours),
        overtime_hours: round(overtime_hours),
        effective_rate_cents: category[:effective_rate_cents],
        entry_ids: category[:entry_ids]
      }
    end

    def week_start(date)
      self.class.fetch_start_for(date, workweek_start_weekday: @workweek_start_weekday)
    end

    def reconciles?(left, right)
      (left.to_f - right.to_f).abs <= RECONCILIATION_TOLERANCE
    end

    def round(value)
      BigDecimal(value.to_s).round(2).to_f
    end
  end
end
