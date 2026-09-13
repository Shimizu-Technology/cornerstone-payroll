# frozen_string_literal: true

# Connects the existing FIT/Form 500 payment workflow to the committed Guam
# income-tax liability journal. This is shared by automatic, operator-requested,
# and corrective-payroll FIT payments so every entry point has the same truth.
class PayrollLiabilityFitPaymentConnector
  def self.connect!(non_employee_check:, pay_period:, actor: nil)
    return non_employee_check if non_employee_check.payroll_liability_check_allocations.exists?

    reversed_source_ids = PayrollLiabilityPosting.reversals.select(:source_posting_id)
    active_postings = pay_period.payroll_liability_postings.source_postings.where.not(id: reversed_source_ids)
    if active_postings.none? && pay_period.payroll_items.exists?
      PayrollLiabilityPostingService.post!(pay_period:, actor:)
    end

    entry_ids = pay_period.payroll_liability_postings.source_postings
      .where.not(id: reversed_source_ids)
      .joins(:entries)
      .merge(PayrollLiabilityEntry.where(
        authority: PayrollLiabilityPostingService::GUAM_DRT,
        category: "guam_income_tax_withheld"
      ))
      .pluck("payroll_liability_entries.id")

    PayrollLiabilityCheckAllocationService.allocate!(
      non_employee_check:,
      entry_ids:
    ) if entry_ids.any?
    non_employee_check.reload
  end
end
