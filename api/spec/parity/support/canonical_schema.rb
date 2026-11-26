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

    # Employee API exposes check_number_last4; client/staff APIs and PDFs carry
    # the full check number. Normalizing to the last 4 characters compares
    # consistently even on 5+ digit check numbers.
    def normalize_check_number(value)
      text = value.to_s.strip
      return nil if text.empty?

      text.last(4)
    end

    # Shared deduction-key normalization reused across API and PDF extractors so
    # label aliases map consistently while preserving each view's raw label.
    def canonical_deduction_key(label)
      text = label.to_s.downcase
      return :roth_401k if text.include?("roth")
      return :retirement_401k if text.include?("401(k)")

      text.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
    end

    def canonical_employer_contribution_key(label)
      text = label.to_s.downcase
      return :employer_roth_401k_match if text.include?("roth")
      return :employer_401k_match if text.include?("401(k)")

      text.sub(/\Aer\s+/, "").gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
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

    def assert_parity!(figure:, values_by_view:, fixture: nil, allow_nil: false)
      raise ArgumentError, "Need at least 2 views to compare parity" if values_by_view.size < 2

      label = Array(figure).join(".")
      scope = fixture ? "[#{fixture}] " : ""

      if !allow_nil && values_by_view.values.any?(&:nil?)
        missing = values_by_view.select { |_, val| val.nil? }.keys.map(&:to_s).join(", ")
        lines = format_view_lines(values_by_view)
        fail_parity!(
          "Missing required figure for #{scope}`#{label}` in view(s) [#{missing}]:\n#{lines}"
        )
        return
      end

      unique_values = values_by_view.values.uniq
      return if unique_values.size == 1

      lines = format_view_lines(values_by_view)
      fail_parity!(
        "Data parity mismatch for #{scope}figure `#{label}`:\n#{lines}"
      )
    end

    # Checks every figure in `figures` inside a single aggregate_failures block
    # so one run reports every divergent figure instead of stopping at the first.
    def assert_parity_table!(views:, figures:, fixture: nil, allow_nil_figures: [])
      allowed = allow_nil_figures.map { |f| Array(f) }
      run_checks = lambda do
        figures.each do |figure|
          assert_parity!(
            fixture: fixture,
            figure: figure,
            values_by_view: views.transform_values { |v| dig_figure(v, figure) },
            allow_nil: allowed.include?(Array(figure))
          )
        end
      end

      if respond_to?(:aggregate_failures)
        aggregate_failures("parity for #{fixture || 'views'}", &run_checks)
      else
        run_checks.call
      end
    end

    def format_view_lines(values_by_view)
      width = values_by_view.keys.map { |k| k.to_s.length }.max
      values_by_view.map do |view, val|
        format("  %-#{width}s  %s", "#{view}:", format_value(val))
      end.join("\n")
    end

    def fail_parity!(message)
      RSpec::Expectations.fail_with(message)
    end
  end
end
