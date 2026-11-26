# frozen_string_literal: true

module PayrollImport
  module RevelHoursValidation
    HOURS_TOLERANCE = BigDecimal("0.01")

    def self.errors(row)
      regular, overtime, doubletime, total, doubletime_pay =
        row.values_at(:regular_hours, :overtime_hours, :doubletime_hours, :total_hours, :doubletime_pay).map(&:to_d)
      gap = total - regular - overtime - doubletime
      errors = []

      if doubletime.positive? || doubletime_pay.positive?
        evidence = if doubletime.positive?
          "#{hours_label(doubletime)} double-time hours"
        else
          "#{ActiveSupport::NumberHelper.number_to_currency(doubletime_pay)} in double-time pay"
        end
        errors << {
          code: "doubletime_not_supported", severity: "error",
          message: "Revel shows #{evidence} for this employee. Payroll can’t import double-time yet. " \
            "Exclude this row, apply the rest, then enter this employee’s hours and double-time pay in the worksheet."
        }
      end

      if gap > HOURS_TOLERANCE
        errors << {
          code: "hours_do_not_reconcile", severity: "error",
          message: "Revel’s total includes #{hours_label(gap)} more hours than this row accounts for. " \
            "Check the report. Exclude this row, apply the rest, then enter this employee’s hours and pay in the worksheet."
        }
      end

      errors
    end

    def self.hours_label(hours)
      hours.to_s("F").delete_suffix(".0")
    end
    private_class_method :hours_label
  end
end
