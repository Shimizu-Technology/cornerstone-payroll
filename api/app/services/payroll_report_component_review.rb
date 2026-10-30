# frozen_string_literal: true

# Main's saved employer field/deduction presentation can be retained without
# claiming a source identity for financial writes. This never proves a payable.
class PayrollReportComponentReview
  CODE = "legacy_employer_benefit_unclassified".freeze
  MESSAGE = "Legacy employer benefit history not yet classified".freeze

  def self.compatible_mirror?(item, field, deduction)
    context = item.calculation_context_snapshot.to_h
    item.persisted? && item.pay_period.committed? && field.employer_contribution? &&
      deduction.employer_contribution? && deduction.deduction_type&.company_id == item.company_id &&
      field.metadata.to_h[PayrollComponentMirrors::IDENTITY_KEY].nil? &&
      !context.key?("built_in_employer_match_mirrors") && !context.key?("corrective_paycheck")
    # The resolver has already required one matching label, amount, treatment
    # and reporting group, excluded frozen independent sources, and enforced
    # one field per deduction. No current employee default is consulted.
  end

  def self.for_item(item)
    PayrollComponentMirrors.resolution(item)
    []
  rescue PayrollComponentMirrors::AmbiguousHistoryError
    # A structurally ambiguous item still fails. Only the compatible saved
    # presentation receives a review flag, never a financial reconciliation.
    PayrollComponentMirrors.resolution(item, for_reporting: true)
    [ { code: CODE, message: MESSAGE, payroll_item_id: item.id, employee_id: item.employee_id } ]
  end

  def self.for_items(items)
    items.flat_map { |item| for_item(item) }
  end
end
