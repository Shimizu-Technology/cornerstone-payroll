# frozen_string_literal: true

module TimeTracking
  class PayloadValidator
    class Error < ArgumentError; end

    CONTRACT_VERSION = "1.0"
    RECONCILIATION_TOLERANCE = BigDecimal("0.01")
    MAX_DAILY_HOURS = BigDecimal("24")

    def initialize(payload:, fetch_start_date:, fetch_end_date:)
      @payload = payload
      @fetch_start_date = fetch_start_date.to_date
      @fetch_end_date = fetch_end_date.to_date
    end

    def validate!
      require_hash!(@payload, "payload")
      validate_contract_version!
      validate_export_range!
      employees = require_array!(@payload["employees"], "employees")
      validate_unique_values!(employees, "source_user_id", "employees")

      employee_totals = employees.each_with_index.map do |employee, index|
        validate_employee!(employee, index)
      end
      validate_summary!(employee_totals)

      @payload
    end

    private

    def validate_contract_version!
      version = @payload["schema_version"].presence || CONTRACT_VERSION
      return if version.to_s == CONTRACT_VERSION

      raise Error, "Unsupported time-summary schema_version #{version}"
    end

    def validate_export_range!
      validate_export_date!("start_date", @fetch_start_date)
      validate_export_date!("end_date", @fetch_end_date)
    end

    def validate_export_date!(key, expected)
      return if @payload[key].blank?

      actual = parse_date!(@payload[key], key)
      raise Error, "#{key} does not match the requested export range" unless actual == expected
    end

    def validate_employee!(employee, index)
      path = "employees[#{index}]"
      require_hash!(employee, path)
      require_string!(employee["source_user_id"], "#{path}.source_user_id")
      days = require_array!(employee["days"], "#{path}.days")
      validate_unique_work_dates!(days, path)

      day_totals = days.each_with_index.map { |day, day_index| validate_day!(day, "#{path}.days[#{day_index}]") }
      total_hours = day_totals.sum { |totals| totals.fetch(:total) }
      reconcile_optional_total!(employee, "total_hours", total_hours, path)
      validate_optional_split!(employee, total_hours, path)

      if split_present?(employee) && day_totals.any? { |totals| totals[:split_provided] }
        unless day_totals.all? { |totals| totals[:split_provided] }
          raise Error, "#{path}.days must all provide regular/overtime splits when employee totals do"
        end

        reconcile!(
          numeric!(employee["regular_hours"], "#{path}.regular_hours"),
          day_totals.sum { |totals| totals.fetch(:regular) },
          "#{path}.regular_hours does not equal the sum of day regular_hours"
        )
        reconcile!(
          numeric!(employee["overtime_hours"], "#{path}.overtime_hours"),
          day_totals.sum { |totals| totals.fetch(:overtime) },
          "#{path}.overtime_hours does not equal the sum of day overtime_hours"
        )
      end

      {
        total: total_hours,
        regular: split_present?(employee) ? numeric!(employee["regular_hours"], "#{path}.regular_hours") : nil,
        overtime: split_present?(employee) ? numeric!(employee["overtime_hours"], "#{path}.overtime_hours") : nil
      }
    end

    def validate_unique_work_dates!(days, employee_path)
      dates = days.each_with_index.map do |day, index|
        require_hash!(day, "#{employee_path}.days[#{index}]")
        parse_date!(day["work_date"], "#{employee_path}.days[#{index}].work_date")
      end
      duplicate = dates.tally.find { |_date, count| count > 1 }&.first
      raise Error, "#{employee_path}.days contains duplicate work_date #{duplicate}" if duplicate
    end

    def validate_day!(day, path)
      work_date = parse_date!(day["work_date"], "#{path}.work_date")
      unless work_date.between?(@fetch_start_date, @fetch_end_date)
        raise Error, "#{path}.work_date is outside the requested export range"
      end

      total_hours = aliased_total!(day, path)
      raise Error, "#{path}.hours cannot exceed 24" if total_hours > MAX_DAILY_HOURS

      regular_hours, overtime_hours = validate_optional_split!(day, total_hours, path)
      categories_value = day.key?("categories") ? day["categories"] : []
      categories = require_array!(categories_value, "#{path}.categories")
      validate_unique_categories!(categories, path)
      category_totals = categories.each_with_index.map do |category, category_index|
        validate_category!(category, "#{path}.categories[#{category_index}]")
      end

      if categories.any?
        reconcile!(
          category_totals.sum { |totals| totals.fetch(:total) },
          total_hours,
          "#{path}.category totals do not equal day hours"
        )
      end

      if category_totals.any? { |totals| totals[:split_provided] }
        unless category_totals.all? { |totals| totals[:split_provided] }
          raise Error, "#{path}.categories must all provide regular/overtime splits when any category does"
        end

        if split_present?(day)
          reconcile!(
            category_totals.sum { |totals| totals.fetch(:regular) },
            regular_hours,
            "#{path}.category regular_hours do not equal day regular_hours"
          )
          reconcile!(
            category_totals.sum { |totals| totals.fetch(:overtime) },
            overtime_hours,
            "#{path}.category overtime_hours do not equal day overtime_hours"
          )
        end
      end

      {
        total: total_hours,
        regular: regular_hours,
        overtime: overtime_hours,
        split_provided: split_present?(day)
      }
    end

    def validate_category!(category, path)
      require_hash!(category, path)
      require_string!(category_identity(category), "#{path} category identity")
      total_hours = aliased_total!(category, path)
      regular_hours, overtime_hours = validate_optional_split!(category, total_hours, path)

      {
        total: total_hours,
        regular: regular_hours,
        overtime: overtime_hours,
        split_provided: split_present?(category)
      }
    end

    def validate_unique_categories!(categories, day_path)
      identities = categories.each_with_index.map do |category, index|
        require_hash!(category, "#{day_path}.categories[#{index}]")
        require_string!(category_identity(category), "#{day_path}.categories[#{index}] category identity")
      end
      duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
      raise Error, "#{day_path}.categories contains duplicate category #{duplicate}" if duplicate
    end

    def category_identity(category)
      value = category["source_category_id"].presence || category["key"].presence || category["name"].presence
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.presence
    end

    def validate_optional_split!(record, total_hours, path)
      regular_present = record.key?("regular_hours")
      overtime_present = record.key?("overtime_hours")
      if regular_present != overtime_present
        raise Error, "#{path} must provide regular_hours and overtime_hours together"
      end
      return [ nil, nil ] unless regular_present

      regular_hours = numeric!(record["regular_hours"], "#{path}.regular_hours")
      overtime_hours = numeric!(record["overtime_hours"], "#{path}.overtime_hours")
      reconcile!(regular_hours + overtime_hours, total_hours, "#{path}.regular_hours plus overtime_hours does not equal total hours")
      [ regular_hours, overtime_hours ]
    end

    def reconcile_optional_total!(record, key, expected, path)
      return unless record.key?(key)

      reconcile!(numeric!(record[key], "#{path}.#{key}"), expected, "#{path}.#{key} does not equal the sum of day hours")
    end

    def validate_summary!(employee_totals)
      summary = @payload["summary"]
      return if summary.nil?

      require_hash!(summary, "summary")
      total_hours = employee_totals.sum { |totals| totals.fetch(:total) }
      reconcile_optional_total!(summary, "countable_hours", total_hours, "summary")
      regular_hours, overtime_hours = validate_optional_split!(summary, total_hours, "summary")

      if split_present?(summary) && employee_totals.any? { |totals| totals[:regular] }
        unless employee_totals.all? { |totals| totals[:regular] && totals[:overtime] }
          raise Error, "employees must all provide regular/overtime splits when summary totals do"
        end

        reconcile!(regular_hours, employee_totals.sum { |totals| totals.fetch(:regular) }, "summary.regular_hours does not equal employee totals")
        reconcile!(overtime_hours, employee_totals.sum { |totals| totals.fetch(:overtime) }, "summary.overtime_hours does not equal employee totals")
      end
    end

    def aliased_total!(record, path)
      hours_present = record.key?("hours")
      total_present = record.key?("total_hours")
      unless hours_present || total_present
        if split_present?(record)
          return numeric!(record["regular_hours"], "#{path}.regular_hours") +
                 numeric!(record["overtime_hours"], "#{path}.overtime_hours")
        end

        raise Error, "#{path} must provide hours, total_hours, or a complete regular/overtime split"
      end

      hours = numeric!(record["hours"], "#{path}.hours") if hours_present
      total = numeric!(record["total_hours"], "#{path}.total_hours") if total_present
      reconcile!(hours, total, "#{path}.hours does not equal total_hours") if hours_present && total_present
      total || hours
    end

    def numeric!(value, path)
      number = BigDecimal(value.to_s, exception: false)
      raise Error, "#{path} must be a finite non-negative number" unless number&.finite? && !number.negative?

      number
    end

    def reconcile!(actual, expected, message)
      return if (actual - expected).abs <= RECONCILIATION_TOLERANCE

      raise Error, message
    end

    def require_hash!(value, path)
      return value if value.is_a?(Hash)

      raise Error, "#{path} must be an object"
    end

    def require_array!(value, path)
      return value if value.is_a?(Array)

      raise Error, "#{path} must be an array"
    end

    def require_string!(value, path)
      return value.to_s if value.present?

      raise Error, "#{path} is required"
    end

    def validate_unique_values!(records, key, path)
      values = records.each_with_index.map do |record, index|
        require_hash!(record, "#{path}[#{index}]")
        require_string!(record[key], "#{path}[#{index}].#{key}")
      end
      duplicate = values.tally.find { |_value, count| count > 1 }&.first
      raise Error, "#{path} contains duplicate #{key} #{duplicate}" if duplicate
    end

    def parse_date!(value, path)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise Error, "#{path} must be a valid ISO 8601 date"
    end

    def split_present?(record)
      record.key?("regular_hours") && record.key?("overtime_hours")
    end
  end
end
