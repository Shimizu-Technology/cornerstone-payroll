# frozen_string_literal: true

class NonEmployeeCheckSupersessionService
  class Error < StandardError; end

  def initialize(check:, actor:)
    @check = check
    @actor = actor
  end

  def candidates
    return [] unless candidate_check?

    PayrollItem.includes(:employee, :pay_period)
      .where(company_id: check.company_id, net_pay: check.amount, voided: false)
      .where.not(check_number: nil)
      .select { |item| eligible_item?(item) }
  end

  def supersede!(payroll_item_id:, reason:)
    note = reason.to_s.strip
    raise Error, "Explain why these records represent one physical check (at least 20 characters)" if note.length < 20

    check.with_lock do
      raise Error, "Only an unvoided, printed, unpaid standalone check can be linked" unless candidate_check?
      raise Error, "This check already has a payroll link" if check.non_employee_check_supersession

      item = check.company.payroll_items.find_by(id: payroll_item_id)
      raise Error, "Choose a matching committed payroll check" unless item

      item.with_lock do
        raise Error, "Choose a matching issued payroll check" unless eligible_item?(item)

        NonEmployeeCheckSupersession.create!(non_employee_check: check, payroll_item: item,
                                            user: actor, reason: note)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    raise Error, "This standalone check or payroll item is already linked"
  end

  private

  attr_reader :check, :actor

  def candidate_check?
    check.standalone? && !check.voided? && check.printed? && check.paid_at.nil? &&
      check.payment_method == "check" && !check.liability_payment? && !check.non_employee_check_supersession &&
      CheckReconciliationStatus.for(check) != "cleared" && normalized_number(check.check_number).present?
  end

  def eligible_item?(item)
    item.pay_period.committed? && !item.pay_period.voided? && item.effective_payment_delivery_method == "paper_check" &&
      CheckReconciliationStatus.for(item).in?(%w[issued cleared]) &&
      normalized_number(item.check_number) == normalized_number(check.check_number)
  end

  def normalized_number(value)
    digits = value.to_s.strip
    return unless digits.match?(/\A\d+\z/)

    digits.to_i.to_s
  end
end
