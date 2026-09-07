# frozen_string_literal: true

module QuickbooksHistory
  module CanonicalJson
    module_function

    def normalize(value)
      case value
      when Hash
        stringified = value.to_h.stringify_keys
        raise ArgumentError, "Canonical JSON contains keys that collide after stringification" if stringified.size != value.to_h.size

        stringified.sort.to_h.transform_values { |nested| normalize(nested) }
      when Array
        value.map { |nested| normalize(nested) }
      when BigDecimal
        (value.zero? ? 0.to_d : value).to_s("F")
      when Date, Time, ActiveSupport::TimeWithZone
        value.iso8601
      else
        value
      end
    end

    def round_trip(value)
      JSON.parse(JSON.generate(normalize(value)))
    end
  end
end
