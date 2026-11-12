# frozen_string_literal: true

module PayrollSubmissions
  # The "Changes this period" form, stored as structured evidence. Rows are
  # validated and normalized here and never applied to payroll or employee
  # records automatically. Bank details are deliberately not collected.
  class ChangeRows
    MAX_ROWS = 100
    MAX_TEXT = 500
    KINDS = {
      "extra_hours" => { employee: :required, fields: { "hours" => :hours } },
      "owner_pay" => { employee: :optional_many, fields: { "amount" => :money, "basis" => :basis } },
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

    def self.normalize!(rows, company_id:)
      new(rows, company_id: company_id).normalize!
    end

    def initialize(rows, company_id:)
      @rows = rows
      @company_id = company_id
      @errors = Hash.new { |hash, key| hash[key] = [] }
    end

    def normalize!
      rows = parse_rows
      raise Invalid, { "changes" => [ "List no more than #{MAX_ROWS} changes" ] } if rows.size > MAX_ROWS

      employee_ids = rows.flat_map { |row| Array(row["employee_ids"]) + [ row["employee_id"] ] }.compact.map { |id| integer(id) }.compact.uniq
      @employees = Employee.where(company_id: @company_id, id: employee_ids).pluck(:id).to_set
      normalized = rows.each_with_index.map { |row, index| normalize_row(row, index) }
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
      case spec[:employee]
      when :required
        id = integer(row["employee_id"])
        if id && @employees.include?(id)
          result["employee_id"] = id
        else
          @errors[key] << "#{LABELS[kind]}: choose an employee from this company"
        end
      when :optional_many
        ids = Array(row["employee_ids"]).map { |value| integer(value) }
        if ids.any? { |id| id.nil? || !@employees.include?(id) }
          @errors[key] << "#{LABELS[kind]}: choose employees from this company"
        else
          result["employee_ids"] = ids.uniq
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
