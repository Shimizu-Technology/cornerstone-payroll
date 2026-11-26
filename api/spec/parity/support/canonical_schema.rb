# frozen_string_literal: true

module Parity
  # Canonical value normalization and table-driven parity assertions.
  # Every extractor maps its view's payload into the same canonical keys so
  # discrepancies produce an exact report of which view and figure differed.
  module CanonicalSchema
    module_function

    def money(value)
      return nil if value.nil? || value == ""

      cleaned = value.is_a?(String) ? value.delete("$,").strip : value
      return nil if cleaned == "—" || cleaned == "-" || cleaned == ""

      BigDecimal(cleaned.to_s).round(2)
    end

    def hours(value)
      money(value)
    end

    def iso_date(value)
      return nil if value.nil? || value == ""
      return value.iso8601 if value.respond_to?(:iso8601)

      text = value.to_s.strip
      return text if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.strptime(text, "%m/%d/%Y").iso8601
    rescue Date::Error
      Date.parse(text).iso8601
    end

    def normalize_phone(value)
      digits = value.to_s.gsub(/\D/, "")
      return nil if digits.empty?

      digits
    end

    def dig_figure(record, figure)
      Array(figure).reduce(record) do |current, key|
        break nil unless current.is_a?(Hash)

        current[key]
      end
    end

    def format_value(value)
      case value
      when BigDecimal
        format("%.2f", value)
      else
        value.inspect
      end
    end

    def assert_parity!(figure:, values_by_view:, fixture: nil)
      raise ArgumentError, "Need at least 2 views to compare parity" if values_by_view.size < 2

      unique_values = values_by_view.values.uniq
      return if unique_values.size == 1

      label = Array(figure).join(".")
      width = values_by_view.keys.map { |k| k.to_s.length }.max
      lines = values_by_view.map do |view, val|
        format("  %-#{width}s  %s", "#{view}:", format_value(val))
      end
      scope = fixture ? "[#{fixture}] " : ""
      raise RSpec::Expectations::ExpectationNotMetError,
        "Data parity mismatch for #{scope}figure `#{label}`:\n#{lines.join("\n")}"
    end
  end
end
