# frozen_string_literal: true

require "set"

module EmployeeDocuments
  module QuickbooksStubNumbers
    SEPARATOR = /(?:[\p{Zs}\t\p{Pd}.\/_]+|[^0-9\r\n·]{1,2})/
    DIGIT_GROUP = /[0-9]+/
    NUMBER_RUN = /#{DIGIT_GROUP}(?:#{SEPARATOR}#{DIGIT_GROUP})*/
    DECIMAL_AMOUNT = /(?<![0-9.])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\.[0-9]{2}(?![0-9]|\s*[.\/_\p{Pd}]\s*[0-9])/
    ACCOUNT_LABEL = /\b(?:routing(?:\s+transit)?|account|check)(?:\s+(?:number|no\.?))?\s*[:#-]?\s*(?=[0-9])/i

    def self.possible_ssn?(text)
      text.each_line.any? do |line|
        cleaned = line.gsub(DECIMAL_AMOUNT, "·")
        labeled_starts = cleaned.to_enum(:scan, ACCOUNT_LABEL).map { Regexp.last_match.end(0) }.to_set
        cleaned.to_enum(:scan, NUMBER_RUN).any? do
          run = Regexp.last_match
          nine_digit_window?(run[0], run.begin(0), labeled_starts)
        end
      end
    end

    def self.nine_digit_window?(run, offset, labeled_starts)
      window = []
      digits = 0
      run.to_enum(:scan, DIGIT_GROUP).any? do
        group = Regexp.last_match
        window << group
        digits += group[0].length
        digits -= window.shift[0].length while digits > 9

        digits == 9 && !labeled_starts.include?(offset + window.first.begin(0))
      end
    end
    private_class_method :nine_digit_window?

    def self.employee_ssn?(text, digits)
      return false unless digits&.match?(/\A[0-9]{9}\z/)

      pattern = /(?<![0-9])#{digits.chars.join("(?:#{SEPARATOR})?")}(?![0-9])/
      text.match?(pattern)
    end
  end
end
