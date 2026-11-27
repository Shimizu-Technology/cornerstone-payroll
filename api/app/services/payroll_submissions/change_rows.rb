# frozen_string_literal: true

module PayrollSubmissions
  # The "Changes this period" form, stored as structured evidence. Rows are
  # validated and normalized here and never applied to payroll or employee
  # records automatically. Bank details are deliberately not collected.
  class ChangeRows
    MAX_ROWS = 100
    MAX_TEXT = 500
    KINDS = {
      "extra_hours" => { employee: :required, fields: {} },
      "owner_pay" => { employee: :required, fields: { "amount" => :money } },
      "paid_leave" => { employee: :required, fields: { "hours" => :hours } },
      "new_hire" => { employee: :none, fields: { "name" => :name, "starting_wage" => :money, "wage_unit" => :wage_unit, "start_date" => :optional_date } },
      "wage_change" => { employee: :required, fields: { "new_wage" => :money, "wage_unit" => :wage_unit, "effective_date" => :optional_date } },
      "deduction" => { employee: :required, fields: { "deduction_action" => :deduction_action, "description" => :name, "amount" => :optional_money } },
      "direct_deposit_addition" => { employee: :required, fields: {} }
    }.freeze
    LABELS = {
      "extra_hours" => "Extra or manual hours",
      "owner_pay" => "Owner pay",
      "paid_leave" => "Paid leave",
      "new_hire" => "New hire",
      "wage_change" => "Wage change",
      "deduction" => "Deduction",
      "direct_deposit_addition" => "Direct deposit addition"
    }.freeze
    BASES = %w[total each].freeze
    WAGE_UNITS = %w[hourly salary].freeze
    DEDUCTION_ACTIONS = %w[start continue stop].freeze

    class Invalid < StandardError
      attr_reader :details

      def initialize(details)
        @details = details
        super(details.values.flatten.first || "Check the changes this period")
      end
    end

    # rates_on: the submission period's end date; extra hours are checked
    # against the job rates in effect on it (M3-4).
    # extra_hours_config: { mode: "split" | "workweek", workweeks: [...] }
    def self.normalize!(rows, company_id:, rates_on: nil, extra_hours_config: nil)
      new(rows, company_id: company_id, rates_on: rates_on, extra_hours_config: extra_hours_config).normalize!
    end

    def initialize(rows, company_id:, rates_on: nil, extra_hours_config: nil)
      @rows = rows
      @company_id = company_id
      @rates_on = rates_on || PayrollBusinessClock.today
      @extra_hours_config = extra_hours_config
      @errors = Hash.new { |hash, key| hash[key] = [] }
    end

    def normalize!
      rows = parse_rows
      raise Invalid, { "changes" => [ "List no more than #{MAX_ROWS} changes" ] } if rows.size > MAX_ROWS

      employee_ids = rows.flat_map { |row| Array(row["employee_ids"]) + [ row["employee_id"] ] }.compact.map { |id| integer(id) }.compact.uniq
      @employees = Employee.where(company_id: @company_id, id: employee_ids).with_compensation_history.index_by(&:id)
      @defaults = PayrollStandingChange.where(company_id: @company_id)
        .preload(employee: %i[employee_compensation_changes employee_wage_rates employee_wage_rate_versions]).index_by(&:id)
      normalized = rows.each_with_index.map { |row, index| normalize_row(row, index) }
      missing = @defaults.values.select { |item| item.active? && item.availability_error(rates_on: @rates_on).nil? && item.required? }.reject { |item| normalized.any? { |row| row["standing_change_id"] == item.id } }
      @errors["changes"] << "Every period defaults changed. Reload and fill in or skip every default." if missing.any?
      duplicates = normalized.select { |row| %w[owner_pay extra_hours].include?(row["kind"]) && !row["skipped"] }
        .group_by { |row| [ row["kind"], row["employee_id"] ] }.values.any?(&:many?)
      @errors["changes"] << "Keep one owner-pay or extra-hours row per employee." if duplicates
      default_ids = normalized.filter_map { |row| row["standing_change_id"] }
      @errors["changes"] << "Keep one answer per every-period default." if default_ids.uniq.size != default_ids.size
      raise Invalid, @errors.to_h if @errors.any?

      normalized
    end

    private

    def parse_rows
      value = @rows
      value = JSON.parse(value) if value.is_a?(String)
      value = value.to_unsafe_h.values if value.respond_to?(:to_unsafe_h)
      value = value.values if value.is_a?(Hash)
      raise Invalid, { "changes" => [ "Changes must be a list" ] } unless value.nil? || value.is_a?(Array)

      Array(value).map do |row|
        row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
        raise Invalid, { "changes" => [ "Each change must be a set of fields" ] } unless row.is_a?(Hash)

        row.stringify_keys
      end
    rescue JSON::ParserError
      raise Invalid, { "changes" => [ "Changes could not be read" ] }
    end

    def normalize_row(row, index)
      key = "changes.#{index + 1}"
      kind = row["kind"].to_s
      spec = KINDS[kind]
      unless spec
        @errors[key] << "Choose what kind of change this is"
        return {}
      end

      result = { "kind" => kind }
      if row["standing_change_id"].present?
        item = @defaults[integer(row["standing_change_id"])]
        unless item && item.active? && item.kind == kind && item.employee_id == integer(row["employee_id"]) && item.employee_wage_rate_id == integer(row["employee_wage_rate_id"])
          @errors[key] << "Every period default changed. Reload before sending."
          return result
        end
        result.merge!("standing_change_id" => item.id, "employee_id" => item.employee_id, "label" => item.display_label)
        availability_error = item.availability_error(rates_on: @rates_on)
        @errors[key] << availability_error if availability_error
        if ActiveModel::Type::Boolean.new.cast(row["skipped"])
          @errors[key] << "#{item.display_label}: enter a value; None this period is not allowed." unless item.allow_none?
          return result.merge("skipped" => true, "employee_wage_rate_id" => item.employee_wage_rate_id).compact
        end
      elsif ActiveModel::Type::Boolean.new.cast(row["skipped"])
        @errors[key] << "Only an every-period default can be marked Not this period."
      end
      case spec[:employee]
      when :required
        id = integer(row["employee_id"])
        if id && @employees.key?(id)
          result["employee_id"] = id
        else
          @errors[key] << "#{LABELS[kind]}: choose an employee from this company"
        end
      when :optional_many
        ids = Array(row["employee_ids"]).map { |value| integer(value) }
        if ids.any? { |id| id.nil? || !@employees.key?(id) }
          @errors[key] << "#{LABELS[kind]}: choose employees from this company"
        else
          result["employee_ids"] = ids.uniq
        end
      end

      employee = @employees[result["employee_id"]]
      if kind == "owner_pay" && employee && (!employee.active? || !employee.payroll_compensation_on(@rates_on).variable_salary?)
        @errors[key] << "Choose an active employee with variable salary for owner pay."
      end
      if kind == "extra_hours" && employee
        compensation = employee.payroll_compensation_on(@rates_on)
        rate = employee.wage_rates_on(@rates_on).find { |candidate| candidate.id == integer(row["employee_wage_rate_id"]) }
        unless employee.active? && compensation.hourly_pay_basis? && rate && !rate.rate.nil?
          @errors[key] << "Choose an active employee and their saved job and rate for extra hours."
        else
          result.merge!("employee_wage_rate_id" => rate.id, "wage_rate_label" => rate.label, "wage_rate" => rate.rate.to_s("F"))
          normalize_extra_hours!(row, result, compensation, key)
        end
      end
      spec[:fields].each do |field, type|
        value = coerce(type, row[field])
        if value == :invalid
          @errors[key] << "#{LABELS[kind]}: #{field_message(field, type)}"
        elsif !value.nil?
          result[field] = value
        end
      end
      note = row["note"].to_s.strip
      @errors[key] << "#{LABELS[kind]}: keep the note under #{MAX_TEXT} characters" if note.length > MAX_TEXT
      result["note"] = note if note.present?
      result
    end

    def normalize_extra_hours!(row, result, compensation, key)
      label = LABELS["extra_hours"]
      if compensation.employment_type == "contractor"
        ot_text = row["overtime_hours"].to_s.strip
        if ot_text.present? && BigDecimal(ot_text, exception: false)&.positive?
          @errors[key] << "#{label}: 1099 contractors do not receive overtime hours"
          return
        end
        raw_hours = row["hours"].to_s.strip.presence || row["regular_hours"].to_s.strip
        hours = decimal(raw_hours, max: 1000, required: true, money: false)
        if hours == :invalid
          @errors[key] << "#{label}: enter hours greater than zero"
        else
          result.merge!("hours" => hours, "hours_mode" => "straight_time")
        end
        return
      end

      mode, workweeks = resolve_extra_hours_mode(row)
      case mode
      when "split"
        reg_text = row["regular_hours"].to_s.strip
        ot_text = row["overtime_hours"].to_s.strip
        if reg_text.empty? && ot_text.empty?
          @errors[key] << "#{label}: enter regular hours and/or overtime hours (at least one greater than zero)"
          return
        end
        reg = reg_text.empty? ? "0" : nonnegative_hours(reg_text)
        ot = ot_text.empty? ? "0" : nonnegative_hours(ot_text)
        if reg == :invalid || ot == :invalid
          @errors[key] << "#{label}: enter valid non-negative regular and overtime hours"
          return
        end
        total = (BigDecimal(reg) + BigDecimal(ot)).round(2)
        if !total.positive? || total > 1000
          @errors[key] << "#{label}: enter regular hours and/or overtime hours greater than zero (up to 1000 total)"
          return
        end
        result.merge!(
          "hours" => PayrollIntake::ExtraHoursPolicy.format_hours(total),
          "regular_hours" => reg,
          "overtime_hours" => ot,
          "hours_mode" => "split"
        )
      when "workweek"
        hours = decimal(row["hours"].to_s.strip, max: 1000, required: true, money: false)
        if hours == :invalid
          @errors[key] << "#{label}: enter hours greater than zero"
        elsif BigDecimal(hours) > 168
          @errors[key] << "#{label}: hours in a single workweek cannot exceed 168"
        end
        chosen_week = if workweeks.size == 1
          raw_wk = integer(row["workweek"])
          if row["workweek"].present? && raw_wk != 1
            @errors[key] << "#{label}: choose a valid workweek for this period"
            nil
          else
            1
          end
        else
          max_week = workweeks.any? ? workweeks.size : 2
          raw_wk = integer(row["workweek"])
          if raw_wk && raw_wk.between?(1, max_week)
            raw_wk
          else
            @errors[key] << "#{label}: choose which workweek the hours were worked"
            nil
          end
        end
        return if hours == :invalid || BigDecimal(hours) > 168 || chosen_week.nil?

        week_meta = workweeks.find { |candidate| candidate[:index] == chosen_week }
        result.merge!(
          "hours" => hours,
          "workweek" => chosen_week,
          "workweek_start_date" => week_meta&.dig(:start_date),
          "workweek_end_date" => week_meta&.dig(:end_date),
          "hours_mode" => "workweek"
        ).compact!
      else
        hours = decimal(row["hours"].to_s.strip, max: 1000, required: true, money: false)
        if hours == :invalid
          @errors[key] << "#{label}: enter hours greater than zero"
        else
          result["hours"] = hours
        end
      end
    end

    def resolve_extra_hours_mode(row)
      if @extra_hours_config.present?
        return [ @extra_hours_config[:mode].to_s, Array(@extra_hours_config[:workweeks]) ]
      end

      return [ "split", [] ] if row.key?("regular_hours") || row.key?("overtime_hours")
      return [ "workweek", [] ] if row["workweek"].present?

      [ "legacy_untyped", [] ]
    end

    def nonnegative_hours(text)
      return :invalid unless text.match?(/\A\d{1,9}(\.\d{1,2})?\z/)

      number = BigDecimal(text)
      return :invalid unless number >= 0 && number <= 1000

      number.to_s("F").delete_suffix(".0")
    end

    def coerce(type, value)
      text = value.to_s.strip
      case type
      when :hours then decimal(text, max: 1000, required: true, money: false)
      when :money then decimal(text, max: 10_000_000, required: true, money: true)
      when :optional_money then text.empty? ? nil : decimal(text, max: 10_000_000, required: true, money: true)
      when :basis then BASES.include?(text) ? text : :invalid
      when :wage_unit then WAGE_UNITS.include?(text) ? text : :invalid
      when :deduction_action then DEDUCTION_ACTIONS.include?(text) ? text : :invalid
      when :name then text.present? && text.length <= 200 ? text : :invalid
      when :optional_date
        return nil if text.empty?

        Date.iso8601(text).iso8601
      end
    rescue Date::Error
      :invalid
    end

    # Money is stored as "1200.00"; hours as "6.5" or "35".
    def decimal(text, max:, required:, money:)
      return :invalid if text.empty? && required
      return :invalid unless text.match?(/\A\d{1,9}(\.\d{1,2})?\z/)

      number = BigDecimal(text)
      return :invalid unless number.positive? && number <= max

      money ? format("%.2f", number) : number.to_s("F").delete_suffix(".0")
    end

    def integer(value)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def field_message(field, type)
      case type
      when :hours then "enter hours greater than zero"
      when :money, :optional_money then "enter an amount greater than zero"
      when :basis then "choose whether the amount is the total or for each owner"
      when :wage_unit then "choose hourly or salary"
      when :deduction_action then "choose start, continue or stop"
      when :optional_date then "enter a valid date"
      else "enter the #{field.tr('_', ' ')}"
      end
    end
  end
end
