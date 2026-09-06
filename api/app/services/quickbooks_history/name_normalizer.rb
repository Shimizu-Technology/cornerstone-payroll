# frozen_string_literal: true

module QuickbooksHistory
  class NameNormalizer
    class << self
      def call(value)
        normalized = value.to_s.scrub("").unicode_normalize(:nfkd)
        ascii = normalized
                .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
                .downcase
                .gsub(/[^a-z0-9]+/, " ")
                .squish
        return ascii if ascii.present?

        normalized.downcase.gsub(/[^\p{L}\p{N}]+/, " ").squish
      end

      def employee(employee)
        call([ employee.last_name, employee.first_name, employee.middle_name ].compact_blank.join(" "))
      end
    end
  end
end
