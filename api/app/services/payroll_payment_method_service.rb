# frozen_string_literal: true

# Changes only how an already-calculated net payment will be delivered. This
# never recalculates gross pay, withholding, liabilities, or YTD amounts.
class PayrollPaymentMethodService
  class Error < StandardError; end
  attr_reader :reapproval_pay_period_ids

  def initialize(payroll_item:, method:, actor:, reason: nil, confirm_not_paid: false, ip_address: nil,
                 update_employee_default: false, retire_existing_check: false, confirm_check_cancelled: false,
                 cancellation_evidence_reference: nil, expected_check_number: nil)
    @item = payroll_item
    @method = method.to_s
    @actor = actor
    @reason = reason.to_s.strip
    @confirm_not_paid = ActiveModel::Type::Boolean.new.cast(confirm_not_paid)
    @ip_address = ip_address
    @update_employee_default = ActiveModel::Type::Boolean.new.cast(update_employee_default)
    @retire_existing_check = ActiveModel::Type::Boolean.new.cast(retire_existing_check)
    @confirm_check_cancelled = ActiveModel::Type::Boolean.new.cast(confirm_check_cancelled)
    @cancellation_evidence_reference = cancellation_evidence_reference.to_s.strip
    @expected_check_number = expected_check_number
    @reapproval_pay_period_ids = []
  end

  def call
    raise Error, "Choose paper check or direct deposit" unless Employee::PAYMENT_DELIVERY_METHODS.include?(method)

    ApplicationRecord.transaction do
      company = Company.lock.find(item.company_id)
      period = PayPeriod.lock.find(item.pay_period_id)
      item.lock!
      raise Error, "Employee payment belongs to a different company" unless period.company_id == company.id
      raise Error, "Employee payment belongs to a different company" unless item.employee.company_id == company.id
      raise Error, "Cannot change a voided payment" if item.voided? || period.voided?
      raise Error, "A payment method cannot be changed in this pay period" unless period.status.in?(%w[draft calculated approved committed])
      raise Error, "There is no net payment to change. Print the earnings statement instead; no check number is needed." unless item.net_pay.to_d.positive?
      raise Error, "This check has cleared. Resolve the bank clearing evidence before changing its delivery method." if CheckReconciliationStatus.for(item) == "cleared"

      old_method = item.effective_payment_delivery_method
      if @expected_check_number && @expected_check_number.to_s != item.check_number.to_s
        raise Error, "The original check number changed. Reopen this payroll and review the current check."
      end
      if @retire_existing_check && (!period.committed? || old_method != "paper_check" || method != "direct_deposit")
        raise Error, "Check retirement is only available when changing a committed paper check to direct deposit"
      end
      unless old_method == method && item.payment_delivery_method == method
        if period.committed?
          change_committed!(company, old_method)
        else
          change_uncommitted!(period)
        end
      end

      if @update_employee_default
        default_service = EmployeePaymentDefaultService.new(employee: item.employee, method: method, actor: actor, ip_address: ip_address)
        default_service.call
        @reapproval_pay_period_ids |= default_service.reapproval_pay_period_ids
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
          reason: reason.presence,
          employee_default_updated: @update_employee_default,
          original_check_retired: @retire_existing_check,
          cancellation_evidence_reference: @cancellation_evidence_reference.presence
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

    @reapproval_pay_period_ids << period.id if period.approved?
    self.class.refresh_review!(period: period, actor: actor)
  end

  def self.refresh_review!(period:, actor:)
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
    unless confirm_not_paid
      raise Error, @retire_existing_check ?
        "Confirm the original check has not been paid and no bank transfer was sent before changing methods" :
        "Confirm that no payment has been issued before switching methods"
    end

    if old_method == "paper_check" && method == "direct_deposit"
      old_number = item.check_number
      has_activity = PayrollPaymentMethodEligibility.new(item).check_has_activity?
      if has_activity && !@retire_existing_check
        raise Error, "This check was prepared, printed, downloaded, or delivered. Use Change payment method to retire the original check with cancellation evidence; a simple switch is not allowed."
      end
      if @retire_existing_check
        raise Error, "The original check number changed. Reopen this payroll and review the current check." if @expected_check_number.to_s != old_number.to_s || old_number.blank?
        raise Error, "Confirm that the original check cannot be paid and record its cancellation or recovery evidence." unless @confirm_check_cancelled && @cancellation_evidence_reference.present?
      end
      item.update!(payment_delivery_method: method, check_number: nil,
        check_printed_at: nil, check_print_count: 0, check_prepared_at: nil, check_prepared_source_updated_at: nil)
      if old_number.present?
        item.check_events.create!(
          user: actor, event_type: "voided", check_number: old_number,
          reason: "Original check retired for direct deposit: #{reason}",
          evidence_reference: @cancellation_evidence_reference.presence,
          details: { payment_delivery_change: true, confirmed_not_paid: true, original_check_cancelled: @confirm_check_cancelled },
          ip_address: ip_address
        )
      end
    elsif old_method == "direct_deposit" && method == "paper_check"
      raise Error, "Check retirement is only available when changing a paper check to direct deposit" if @retire_existing_check
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
