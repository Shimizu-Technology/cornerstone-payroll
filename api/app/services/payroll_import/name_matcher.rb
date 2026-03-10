# frozen_string_literal: true

module PayrollImport
  # Matches employee names from PDF/Excel to database Employee records
  #
  # PDF format: "Last, First M." (e.g., "Arthur, Juile R.")
  # Excel format: separate last_name / first_name columns
  #
  # Matching strategy:
  # 1. Exact match on last_name + first_name
  # 2. Fuzzy match using fuzzy_match gem (Levenshtein distance)
  class NameMatcher
    CONFIDENCE_EXACT = 1.0
    CONFIDENCE_THRESHOLD = 0.6

    FIRST_NAME_ALIASES = {
      "kyle a" => "kyle",
      "kyle richard" => "kyle",
      "jayden m" => "jayden",
      "maria carmella" => "maria"
    }.freeze

    attr_reader :employees

    def initialize(employees)
      @employees = employees
      @matcher = build_fuzzy_matcher
    end

    # Match a "Last, First M." formatted name from the PDF
    # @param full_name [String] e.g., "Arthur, Juile R."
    # @return [Hash, nil] { employee_id:, confidence:, matched_name: } or nil
    def match_pdf_name(full_name)
      parsed = parse_pdf_name(full_name)
      return nil unless parsed

      match_name(parsed[:last_name], parsed[:first_name], parsed[:first_token])
    end

    # Match separate last/first name from Excel
    # @param last_name [String]
    # @param first_name [String]
    # @return [Hash, nil] { employee_id:, confidence:, matched_name: } or nil
    def match_excel_name(last_name, first_name)
      match_name(normalize_token(last_name), normalize_first_name(first_name))
    end

    private

    def parse_pdf_name(full_name)
      return nil if full_name.blank?

      parts = full_name.split(",", 2)
      return nil if parts.length < 2

      last_name = normalize_token(parts[0])
      first_segment = normalize_token(parts[1])
      return nil if last_name.blank?

      full_first = normalize_first_name(first_segment)
      first_token = normalize_first_name(first_segment.split(/\s+/).first)

      { last_name: last_name, first_name: full_first, first_token: first_token }
    end

    def match_name(last_name, first_name, first_token = nil)
      return nil if last_name.blank?

      # Try exact match first (full first name then first token fallback)
      exact = find_exact_match(last_name, first_name) || find_exact_match(last_name, first_token)
      return exact if exact

      # Try fuzzy match
      fuzzy = find_fuzzy_match(last_name, first_name)
      return fuzzy if fuzzy

      nil
    end

    def find_exact_match(last_name, first_name)
      match = employees.find do |emp|
        emp_last = normalize_token(emp.last_name)
        emp_first = normalize_first_name(emp.first_name)

        emp_last == normalize_token(last_name) &&
          first_name.present? &&
          emp_first == normalize_first_name(first_name)
      end

      return nil unless match

      {
        employee_id: match.id,
        confidence: CONFIDENCE_EXACT,
        matched_name: match.full_name
      }
    end

    def find_fuzzy_match(last_name, first_name)
      search_name = "#{normalize_token(last_name)} #{normalize_first_name(first_name)}".strip
      result = @matcher.find(search_name)
      return nil unless result

      # Find the employee that matches
      match = employees.find { |emp| "#{normalize_token(emp.last_name)} #{normalize_first_name(emp.first_name)}".strip == result }
      return nil unless match

      # Calculate confidence based on Levenshtein distance
      distance = levenshtein_distance(search_name, result)
      max_len = [ search_name.length, result.length ].max
      confidence = max_len.zero? ? 0.0 : (1.0 - (distance.to_f / max_len)).round(2)

      return nil if confidence < CONFIDENCE_THRESHOLD

      {
        employee_id: match.id,
        confidence: confidence,
        matched_name: match.full_name
      }
    end

    def build_fuzzy_matcher
      candidates = employees.map { |emp| "#{normalize_token(emp.last_name)} #{normalize_first_name(emp.first_name)}".strip }
      FuzzyMatch.new(candidates)
    end

    def normalize_token(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squeeze(" ").strip
    end

    def normalize_first_name(value)
      normalized = normalize_token(value)
      FIRST_NAME_ALIASES.fetch(normalized, normalized)
    end

    # Pure Ruby Levenshtein distance (fallback if levenshtein-ffi native ext unavailable)
    def levenshtein_distance(s, t)
      return Levenshtein.distance(s, t) if defined?(Levenshtein)

      m = s.length
      n = t.length
      d = Array.new(m + 1) { |i| i }
      (1..n).each do |j|
        prev = d[0]
        d[0] = j
        (1..m).each do |i|
          cost = s[i - 1] == t[j - 1] ? 0 : 1
          temp = d[i]
          d[i] = [ d[i] + 1, d[i - 1] + 1, prev + cost ].min
          prev = temp
        end
      end
      d[m]
    end
  end
end
