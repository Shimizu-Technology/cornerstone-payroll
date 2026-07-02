# frozen_string_literal: true

module PayrollIntake
  class EmployeeMatcher
    NAME_SUFFIXES = %w[jr sr ii iii iv v].freeze
    CONFIDENCE_THRESHOLD = 0.70

    def initialize(company:)
      @employees = Employee.active.where(company_id: company.id).includes(:employee_wage_rates).to_a
    end

    def match(source_name)
      normalized_source = normalize_name(source_name)
      return unmatched(source_name) if normalized_source.blank?

      best = employees.filter_map do |employee|
        score_employee(normalized_source, employee)
      end.max_by { |candidate| candidate[:confidence] }

      return unmatched(source_name) unless best && best[:confidence] >= CONFIDENCE_THRESHOLD

      best
    end

    private

    attr_reader :employees

    def unmatched(source_name)
      {
        employee_id: nil,
        employee_name: nil,
        confidence: 0.0,
        method: nil,
        source_name: source_name.to_s
      }
    end

    def score_employee(source, employee)
      employee_full = normalize_name(employee.full_name)
      employee_reversed = normalize_name([ employee.last_name, employee.first_name ].join(" "))
      employee_first = normalize_token(employee.first_name)
      employee_last = normalize_token(employee.last_name)
      source_tokens = source.split
      source_first = source_tokens.first.to_s
      source_last = source_tokens.last.to_s

      score, method = if source == employee_full || source == employee_reversed
        [ 1.0, "exact" ]
      elsif source.delete(" ") == employee_full.delete(" ") || source.delete(" ") == employee_reversed.delete(" ")
        [ 0.98, "normalized_exact" ]
      elsif source.include?(employee_full) || employee_full.include?(source)
        [ 0.92, "substring" ]
      elsif source_last == employee_last && source_first == employee_first
        [ 0.95, "first_last" ]
      elsif source_last == employee_last && (source_first.start_with?(employee_first[0].to_s) || employee_first.start_with?(source_first))
        [ 0.82, "last_name_initial" ]
      elsif source_tokens.include?(employee_last) && source_tokens.include?(employee_first)
        [ 0.88, "token" ]
      else
        fuzzy_score(source, employee_full, employee_reversed)
      end

      return nil unless score.positive?

      {
        employee_id: employee.id,
        employee_name: employee.full_name,
        confidence: score.round(2),
        method: method,
        source_name: source
      }
    end

    def fuzzy_score(source, employee_full, employee_reversed)
      distance = [ levenshtein(source, employee_full), levenshtein(source, employee_reversed) ].min
      max_length = [ source.length, employee_full.length, employee_reversed.length, 1 ].max
      score = 1.0 - (distance.to_f / max_length)
      score >= 0.75 ? [ score, "fuzzy" ] : [ 0.0, nil ]
    end

    def normalize_name(value)
      value.to_s
        .downcase
        .gsub(/[^a-z\s,.-]/, " ")
        .tr(",.-", " ")
        .split
        .reject { |token| NAME_SUFFIXES.include?(token) }
        .join(" ")
    end

    def normalize_token(value)
      normalize_name(value).split.first.to_s
    end

    def levenshtein(a, b)
      a = a.to_s
      b = b.to_s
      return b.length if a.empty?
      return a.length if b.empty?

      costs = (0..b.length).to_a
      a.chars.each_with_index do |char_a, i|
        costs[0] = i + 1
        corner = i
        b.chars.each_with_index do |char_b, j|
          upper = costs[j + 1]
          costs[j + 1] = if char_a == char_b
            corner
          else
            [ corner, upper, costs[j] ].min + 1
          end
          corner = upper
        end
      end
      costs[b.length]
    end
  end
end
