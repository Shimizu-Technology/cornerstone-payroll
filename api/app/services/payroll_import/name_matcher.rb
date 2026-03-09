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

      match_name(parsed[:last_name], parsed[:first_name])
    end

    # Match separate last/first name from Excel
    # @param last_name [String]
    # @param first_name [String]
    # @return [Hash, nil] { employee_id:, confidence:, matched_name: } or nil
    def match_excel_name(last_name, first_name)
      match_name(last_name&.strip, first_name&.strip)
    end

    private

    def parse_pdf_name(full_name)
      return nil if full_name.blank?

      # Expected format: "Last, First M." or "Last, First"
      parts = full_name.split(",", 2)
      return nil if parts.length < 2

      last_name = parts[0].strip
      # Remove middle initial/name suffix
      first_name = parts[1].strip.split(/\s+/).first

      { last_name: last_name, first_name: first_name }
    end

    def match_name(last_name, first_name)
      return nil if last_name.blank?

      # Try exact match first
      exact = find_exact_match(last_name, first_name)
      return exact if exact

      # Try fuzzy match
      fuzzy = find_fuzzy_match(last_name, first_name)
      return fuzzy if fuzzy

      nil
    end

    def find_exact_match(last_name, first_name)
      match = employees.find do |emp|
        emp.last_name.downcase == last_name.downcase &&
          (first_name.blank? || emp.first_name.downcase == first_name.downcase)
      end

      return nil unless match

      {
        employee_id: match.id,
        confidence: CONFIDENCE_EXACT,
        matched_name: match.full_name
      }
    end

    def find_fuzzy_match(last_name, first_name)
      search_name = "#{last_name} #{first_name}".strip.downcase
      result = @matcher.find(search_name)
      return nil unless result

      # Find the employee that matches
      match = employees.find { |emp| "#{emp.last_name} #{emp.first_name}".downcase == result }
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
      candidates = employees.map { |emp| "#{emp.last_name} #{emp.first_name}".downcase }
      FuzzyMatch.new(candidates)
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
