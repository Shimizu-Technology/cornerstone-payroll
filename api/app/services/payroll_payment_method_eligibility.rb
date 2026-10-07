# frozen_string_literal: true

# Shared by the read-only UI preview and the mutation's locked validation.
# A delivery preference does not prove that money was transferred.
class PayrollPaymentMethodEligibility
  def initialize(item)
    @item = item
  end

  def call
    target = item.effective_payment_delivery_method == "direct_deposit" ? "paper_check" : "direct_deposit"
    result = {
      eligible: false, mode: "blocked", reason: nil, target_method: target,
      original_check_number: item.check_number,
      requires_unpaid_confirmation: item.pay_period.committed?, requires_check_cancellation: false
    }
    reason = if item.voided? || item.pay_period.voided?
      "This payment is voided. Its delivery method cannot be changed."
    elsif !item.pay_period.status.in?(%w[draft calculated approved committed])
      "Payment methods cannot be changed in this payroll's current state."
    elsif !item.net_pay.to_d.positive?
      "There is no net payment to change. Print the earnings statement instead; no check number is needed."
    elsif CheckReconciliationStatus.for(item) == "cleared"
      "This check has cleared. Resolve the bank clearing evidence before changing its delivery method."
    elsif !item.pay_period.committed? && target == "direct_deposit" && item.check_number.present?
      "Remove the draft check number before choosing direct deposit."
    elsif target == "paper_check" && item.check_number.present?
      "A check number is already assigned. Review this record before changing its delivery method."
    end
    return result.merge(reason: reason) if reason

    retirement = item.pay_period.committed? && target == "direct_deposit" && check_has_activity?
    result.merge(
      eligible: true, mode: retirement ? "retire_check" : "simple",
      requires_check_cancellation: retirement,
      reason: retirement ? "Cancel or recover the original check and record evidence before changing to direct deposit. Do not continue while the original check could still be paid." : nil
    )
  end

  def check_has_activity?
    item.check_prepared? ||
      item.check_events.where(event_type: %w[prepared printed batch_downloaded delivered],
        check_number: [ nil, "", item.check_number ]).exists? ||
      item.pay_period.check_print_runs.any? do |run|
        run.manifest.any? do |entry|
          references_item = entry["key"] == "payroll_item:#{item.id}" ||
            (entry["source_type"] == "payroll_item" && entry["source_id"].to_s == item.id.to_s)
          references_item &&
            (entry["check_number"].blank? || entry["check_number"].to_s == item.check_number.to_s)
        end
      end
  end

  private

  attr_reader :item
end
