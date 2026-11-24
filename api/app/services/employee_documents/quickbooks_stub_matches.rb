# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksStubMatches
    Match = Data.define(:page, :check, :status)
    DATE = /^\s*(?:pay(?:ment)? date|check date)\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{4}|\d{4}-\d{2}-\d{2})(?!\d)/i
    NET = /^\s*net pay\s*:?\s*(-?\s*\$?\s*(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?!\d)/i
    CHECK_NUMBER = /^\s*(?:check\s*(?:no\.?|number|#))\s*:?\s*(\d+)\b/i

    def initialize(company_id, pages)
      @pages = pages
      @checks = QuickbooksHistory.scope(company_id)
    end

    def call
      matches = @pages.map { |page| match(page) }
      occurrences = matches.filter_map { |match| match.check&.id }.tally
      matches.map do |match|
        occurrences.fetch(match.check&.id, 0) > 1 ? Match.new(page: match.page, check: nil, status: "duplicate_page") : match
      end
    end

    private

    def match(page)
      return Match.new(page:, check: nil, status: page.issue) if page.issue

      date = date_from(page.text)
      net = extract(page.text, NET)&.delete(" $,\t")&.to_d
      names = page.text.lines.map do |line|
        normalize(line.sub(/^[ 	]*(?:employee(?: name)?|payee)(?:[ 	]*:[ 	]*|[ 	]{2,})/i, ""))
      end
      check_numbers = page.text.scan(CHECK_NUMBER).flatten.uniq
      return Match.new(page:, check: nil, status: "ambiguous") if check_numbers.many?
      return Match.new(page:, check: nil, status: "unmatched") unless date && net

      check_number = check_numbers.first

      candidates = @checks.where(pay_date: date, net_pay: net)
        .includes(:employee).select do |check|
          (names.include?(normalize(check.source_employee_name)) || names.include?(normalize(check.employee.full_name))) &&
            (check_number.nil? || check.check_number.to_s.sub(/\A0+(?=\d)/, "") == check_number.sub(/\A0+(?=\d)/, ""))
        end
      return Match.new(page:, check: nil, status: "ambiguous") if candidates.many?

      check = candidates.first
      return Match.new(page:, check: nil, status: "unmatched") unless check
      return Match.new(page:, check: nil, status: "full_ssn") if employee_ssn?(page, check.employee)

      status = if page.possible_ssn
        "possible_ssn"
      elsif page.has_image
        "image_review"
      else
        "matched"
      end
      Match.new(page:, check:, status:)
    end

    def extract(text, pattern)
      values = text.scan(pattern).flatten.uniq
      values.first if values.one?
    end

    def date_from(text)
      value = extract(text, DATE)
      return unless value

      Date.strptime(value, value.include?("/") ? "%m/%d/%Y" : "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    def normalize(name)
      ::QuickbooksHistory::NameNormalizer.call(name)
    end

    def employee_ssn?(page, employee)
      digits = employee.ssn_digits
      [ page.original_text, page.text ].any? { |text| QuickbooksStubNumbers.employee_ssn?(text, digits) }
    end
  end
end
