# frozen_string_literal: true

# A direct amount has no loan identity and is separate from named repayments.
# Before commit, make sure it has not silently replaced a due ledger payment on
# a paycheck saved under the older suppression behavior.
class PayrollLoanConfigurationGuard
  def self.validate!(employee:, payroll_item:)
    return unless payroll_item.loan_deduction.to_d.positive?

    pay_date = payroll_item.pay_period.pay_date
    loans = employee.employee_loans.includes(:deduction_type).select do |loan|
      requested_amount = loan.payment_amount || loan.current_balance || 0
      loan.scheduled_payment_for(pay_date: pay_date, requested_amount: requested_amount).positive? &&
        loan.repayment_schedule_active_on?(pay_date)
    end
    available = payroll_item.payroll_item_deductions.select { |deduction| deduction.amount.to_d.positive? }
    shared_type_ids = loans.group_by(&:deduction_type_id).select { |type_id, group| type_id.present? && group.size > 1 }.keys
    missing = loans.reject do |loan|
      match_index = available.index { |deduction| deduction.employee_loan_id == loan.id }
      if match_index.nil? && loan.deduction_type_id.present? && !shared_type_ids.include?(loan.deduction_type_id)
        match_index = available.index do |deduction|
          deduction.employee_loan_id.blank? && deduction.deduction_type_id == loan.deduction_type_id
        end
      end
      available.delete_at(match_index) if match_index
      match_index.present?
    end
    return if missing.empty?

    raise ArgumentError, "The named deduction for #{missing.map(&:name).join(', ')} is missing. Unapprove and recalculate this payroll; the separate direct amount is not recorded in that ledger."
  end
end
