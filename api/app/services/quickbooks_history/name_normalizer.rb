# frozen_string_literal: true

module QuickbooksHistory
  class NameNormalizer
    class << self
      def call(value)
        value.to_s
             .scrub("")
             .unicode_normalize(:nfkd)
             .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
             .downcase
             .gsub(/[^a-z0-9]+/, " ")
             .squish
      end

      def employee(employee)
        call([ employee.last_name, employee.first_name, employee.middle_name ].compact_blank.join(" "))
      end
    end
  end
end
