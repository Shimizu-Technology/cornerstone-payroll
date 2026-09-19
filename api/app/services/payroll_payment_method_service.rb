# frozen_string_literal: true

# Changes only how an already-calculated net payment will be delivered. This
# never recalculates gross pay, withholding, liabilities, or YTD amounts.
class PayrollPaymentMethodService
  class Error < StandardError; end

  def initialize(payroll_item:, method:, actor:, reason: nil, confirm_not_paid: false, ip_address: nil)
    @item = payroll_item
    @method = method.to_s
    @actor = actor
    @reason = reason.to_s.strip
    @confirm_not_paid = ActiveModel::Type::Boolean.new.cast(confirm_not_paid)
    @ip_address = ip_address
  end

  def call
    raise Error, "Choose paper check or direct deposit" unless Employee::PAYMENT_DELIVERY_METHODS.include?(method)

    ApplicationRecord.transaction do
      company = Company.lock.find(item.company_id)
      period = PayPeriod.lock.find(item.pay_period_id)
      item.lock!
      raise Error, "Employee payment belongs to a different company" unless period.company_id == company.id
      raise Error, "Cannot change a voided payment" if item.voided?
      raise Error, "A payment method cannot be changed in this pay period" unless period.status.in?(%w[draft calculated approved committed])

      old_method = item.effective_payment_delivery_method
      return item if old_method == method && item.payment_delivery_method == method

      if period.committed?
        change_committed!(company, old_method)
      else
        change_uncommitted!(period)
      end

      AuditLog.record!(
        user: actor,
        company_id: company.id,
        action: "payroll_item#payment_delivery_method_changed",
        record_type: "PayrollItem",
        record_id: item.id,
        subject_name: item.employee_full_name,
        metadata: {
          pay_period_id: period.id,
          from: old_method,
          to: method,
          committed: period.committed?,
          reason: reason.presence
        },
        ip_address: ip_address
      )
    end
    item.reload
  end

  private

  attr_reader :item, :method, :actor, :reason, :confirm_not_paid, :ip_address

  def change_uncommitted!(period)
    if method == "direct_deposit" && item.check_number.present?
      raise Error, "Remove the draft check number before choosing direct deposit"
    end

    item.update!(payment_delivery_method: method)
    return unless period.calculated? || period.approved?

    if period.approved?
      period.update!(
        status: "calculated",
        approved_at: nil,
        approved_by_id: nil,
        unapproved_at: Time.current,
        unapproved_by_id: actor&.id
      )
    end
    period.supersede_current_review_package!(reason: "Payment delivery changed; review and approve this run again.")
    PayrollReview::RevisionService.new(pay_period: period, actor: actor).issue!
  end

  def change_committed!(company, old_method)
    raise Error, "Enter a reason of at least 10 characters for a committed payment change" if reason.length < 10
    raise Error, "Confirm that no payment has been issued before switching methods" unless confirm_not_paid

    if old_method == "paper_check" && method == "direct_deposit"
      old_number = item.check_number
      if item.check_printed_at.present? ||
         item.check_events.where(event_type: %w[printed batch_downloaded delivered]).exists? ||
         item.pay_period.check_print_runs.any? { |run| run.manifest.any? { |entry| entry["key"] == "payroll_item:#{item.id}" } } ||
         CheckReconciliationStatus.for(item) == "cleared"
        raise Error, "This check was printed, downloaded, delivered, or cleared. Use the check correction flow; do not switch delivery methods here."
      end
      item.update!(payment_delivery_method: method, check_number: nil)
      if old_number.present?
        item.check_events.create!(
          user: actor, event_type: "voided", check_number: old_number,
          reason: "Unissued check retired for direct deposit: #{reason}", ip_address: ip_address
        )
      end
    elsif old_method == "direct_deposit" && method == "paper_check"
      raise Error, "A check number is already assigned" if item.check_number.present?

      new_number = company.next_check_number!
      item.update!(payment_delivery_method: method, check_number: new_number)
      item.check_events.create!(
        user: actor, event_type: "assigned", check_number: new_number,
        reason: "Assigned after unissued direct deposit was changed to paper check: #{reason}",
        ip_address: ip_address
      )
    else
      raise Error, "This payment method change is not supported"
    end
  end
end
