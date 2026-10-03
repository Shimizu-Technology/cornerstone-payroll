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

  def supersede!(payroll_item_id:, reason:, recipient_verified:)
    note = reason.to_s.strip
    raise Error, "Explain why these records represent one physical check (at least 20 characters)" if note.length < 20
    raise Error, "Confirm that both records name the recipient of the same physical check" unless recipient_verified == true
    unless StaffRolePolicy.allowed?(actor, :manage_client_configuration) && actor.can_access_company?(check.company_id)
      raise Error, "Only an authorized manager or administrator can link duplicate checks"
    end
    if check.company.live_payroll? && !CheckSupersessionRolloutApproval.exists?(company_id: check.company_id)
      raise Error, "Live-check reconciliation is disabled until this company is approved for rollout"
    end

    check.with_lock do
      raise Error, "Only an unvoided, printed, unpaid standalone check can be linked" unless candidate_check?
      raise Error, "This check already has a payroll link" if check.non_employee_check_supersession

      item = check.company.payroll_items.find_by(id: payroll_item_id)
      raise Error, "Choose a matching committed payroll check" unless item

      item.with_lock do
        raise Error, "Choose a matching issued payroll check" unless eligible_item?(item)
        delivery = delivery_event(item)

        NonEmployeeCheckSupersession.create!(non_employee_check: check, payroll_item: item,
                                            company: check.company, user: actor, reason: note,
                                            verified_facts: {
                                              standalone_payee: check.payable_to,
                                              payroll_employee_id: item.employee_id,
                                              payroll_employee_name: item.employee.full_name,
                                              standalone_check_number: check.check_number,
                                              payroll_check_number: item.check_number,
                                              normalized_check_number: normalized_number(item.check_number),
                                              standalone_amount: check.amount.to_s,
                                              payroll_net_amount: item.net_pay.to_s,
                                              delivery_event_id: delivery.id,
                                              delivered_on: delivery.effective_on.iso8601,
                                              delivery_evidence_type: delivery.evidence_type,
                                              delivery_evidence_reference: delivery.evidence_reference,
                                              recipient_verified: true
                                            })
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
      normalized_number(item.check_number) == normalized_number(check.check_number) && delivery_event(item).present?
  end

  def delivery_event(item)
    item.check_events.where(event_type: "delivered", check_number: item.check_number).order(:id).last
  end

  def normalized_number(value)
    digits = value.to_s.strip
    return unless digits.match?(/\A\d+\z/)

    digits.to_i.to_s
  end
end
