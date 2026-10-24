# frozen_string_literal: true

# Ordinary snapshots prove a current-paycheck classification. Corrective
# snapshots remain absolute targets; only their scoped metadata is additive.
class PayrollRetirementCatchUp
  class UnprovedHistoryError < ArgumentError; end

  def self.for_item(item)
    absolute = item.retirement_rule_snapshot.to_h.dig("annual_additions", "current_catch_up").to_d
    return absolute unless item.correction_for_payroll_item_id

    context = item.calculation_context_snapshot.to_h.fetch("corrective_paycheck", {})
    if item.signed_correction_components? && context["catch_up_ledger_version"] == 1
      delta = BigDecimal(context["catch_up_classification_delta"].to_s, exception: false)
      return delta if delta&.finite?
    end
    original = item.correction_for_payroll_item
    original_absolute = original&.retirement_rule_snapshot.to_h.dig("annual_additions", "current_catch_up").to_d
    return 0.to_d if absolute.zero? && original_absolute.zero?

    raise UnprovedHistoryError, "An active correction lacks a proved signed catch-up classification; arrange a reviewed annual retirement reconciliation before processing payroll"
  end
end
