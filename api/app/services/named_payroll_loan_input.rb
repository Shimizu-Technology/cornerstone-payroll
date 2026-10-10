# frozen_string_literal: true

# Repayment intent is keyed by ledger identity, separate from a standalone
# deduction. An explicit zero skips this loan on this paycheck only.
class NamedPayrollLoanInput
  def self.apply!(payroll_item:, inputs:)
    values = inputs.respond_to?(:to_unsafe_h) ? inputs.to_unsafe_h : inputs
    raise ArgumentError, "Named loan inputs must be an object" unless values.is_a?(Hash)
    saved = payroll_item.named_loan_payments.to_h.deep_dup
    values.each do |id, raw|
      raise ArgumentError, "Loan ID is invalid" unless id.to_s.match?(/\A[1-9]\d*\z/)
      loan_id = Integer(id.to_s, 10)
      loan = payroll_item.employee.employee_loans.find_by(id: loan_id, company_id: payroll_item.company_id)
      raise ArgumentError, "Loan does not belong to this employee and client" unless loan
      data = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      raise ArgumentError, "Named loan input must include a mode and amount" unless data.is_a?(Hash)
      case data["mode"] || data[:mode]
      when "default"
        saved.delete(loan_id.to_s)
      when "override"
        amount = BigDecimal((data["amount"] || data[:amount]).to_s)
        raise ArgumentError, "#{loan.name}: repayment must be zero or a positive finite amount" unless amount.finite? && amount >= 0
        saved[loan_id.to_s] = amount.round(2).to_s("F")
      else
        raise ArgumentError, "Named loan input mode must be default or override"
      end
    end
    payroll_item.named_loan_payments = saved
    validate!(payroll_item)
  rescue TypeError, FloatDomainError
    raise ArgumentError, "Named loan input is invalid"
  end

  def self.validate!(payroll_item)
    payroll_item.named_loan_payments.to_h.each do |id, requested|
      loan = payroll_item.employee.employee_loans.find_by(id: id, company_id: payroll_item.company_id)
      raise ArgumentError, "Loan does not belong to this employee and client" unless loan
      amount = BigDecimal(requested.to_s)
      raise ArgumentError, "#{loan.name}: repayment must be zero or greater" unless amount.finite? && amount >= 0
      next unless amount.positive?
      unless loan.active? && loan.repayment_schedule_active_on?(payroll_item.pay_period.pay_date) &&
          loan.scheduled_payment_for(pay_date: payroll_item.pay_period.pay_date, requested_amount: amount).positive?
        raise ArgumentError, "#{loan.name}: repayment is not active for this pay date; review the saved loan schedule"
      end
    end
  end

  def self.options(pay_period)
    items = pay_period.payroll_items.includes(:payroll_item_deductions).index_by(&:employee_id)
    EmployeeLoan.where(company_id: pay_period.company_id).includes(:employee, :deduction_type).order(:employee_id, :id).map do |loan|
      item = items[loan.employee_id]
      explicit = item ? item.named_loan_payments.to_h : {}
      requested = explicit[loan.id.to_s]
      eligible = loan.active? && loan.repayment_schedule_active_on?(pay_period.pay_date) &&
        loan.scheduled_payment_for(pay_date: pay_period.pay_date, requested_amount: 1).positive?
      applied = item&.payroll_item_deductions&.select { |row| row.employee_loan_id == loan.id }&.sum { |row| row.amount.to_d }
      { employee_id: loan.employee_id, loan_id: loan.id, name: loan.name,
        tracking_mode: loan.tracking_mode, current_balance: loan.current_balance&.to_f,
        scheduled_amount: loan.scheduled_payment_for(pay_date: pay_period.pay_date, requested_amount: scheduled_request(loan, pay_period.pay_date)).to_f,
        eligible: eligible, unavailable_reason: eligible ? nil : "Loan schedule is not active for this pay date",
        current_amount: applied&.to_f, mode: requested.nil? ? "default" : "override", requested_amount: requested&.to_d&.to_f }
    end
  end
  def self.scheduled_request(loan, pay_date)
    return loan.payment_amount if loan.payment_amount.present?
    legacy = loan.employee.employee_deductions.active.find_by(deduction_type_id: loan.deduction_type_id) if loan.deduction_type_id
    return legacy.amount if legacy && !legacy.is_percentage?
    assignment = loan.employee_payroll_fields.active.effective_on(pay_date).includes(:payroll_field_definition).first
    return 0 unless assignment
    assignment.amount || assignment.payroll_field_definition.default_amount || 0
  end
end
