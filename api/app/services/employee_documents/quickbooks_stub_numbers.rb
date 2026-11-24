# frozen_string_literal: true

module EmployeeDocuments
  module QuickbooksStubNumbers
    SEPARATOR = /(?:[\p{Zs}\t\p{Pd}.\/_]+|[^0-9\r\n·]{1,2})/
    RUN = /[0-9]+(?:#{SEPARATOR}[0-9]+)*/
    DECIMAL_AMOUNT = /(?<![0-9.])(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\.[0-9]{2}(?![0-9]|\s*[.\/_\p{Pd}]\s*[0-9])/
    ACCOUNT_LABEL = /\b(?:routing(?:\s+transit)?|account|check)(?:\s+(?:number|no\.?))?\s*[:#-]?\s*\z/i
    SSN_LABEL = /\b(?:SSN|social security(?: number)?)\s*:?\s*\z/i

    def self.possible_ssn?(text)
      text.each_line.any? do |line|
        cleaned = line.gsub(DECIMAL_AMOUNT, "·")
        cleaned.to_enum(:scan, RUN).any? do
          match = Regexp.last_match
          run = match[0]
          prefix = cleaned[0...match.begin(0)]
          next false if ACCOUNT_LABEL.match?(prefix)
          next false if run.delete("^0-9").length != 9

          # Three numeric columns separated by ordinary spaces are common on stubs.
          !/\A[0-9]{3} [0-9]{2} [0-9]{4}\z/.match?(run) || SSN_LABEL.match?(prefix)
        end
      end
    end

    def self.employee_ssn?(text, digits)
      return false unless digits&.match?(/\A[0-9]{9}\z/)

      pattern = /(?<![0-9])#{digits.chars.join("(?:#{SEPARATOR})?")}(?![0-9])/
      text.match?(pattern)
    end
  end
end
