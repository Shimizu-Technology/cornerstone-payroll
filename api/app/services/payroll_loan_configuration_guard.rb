# frozen_string_literal: true

# A direct amount has no loan identity. It must not replace a scheduled payment
# whose balance needs to move when this paycheck is committed.
class PayrollLoanConfigurationGuard
  def self.validate!(employee:, payroll_item:)
    return unless payroll_item.loan_deduction.to_d.positive?

    pay_date = payroll_item.pay_period.pay_date
    loans = employee.employee_loans.includes(:deduction_type).select do |loan|
      loan.scheduled_payment_for(pay_date: pay_date, requested_amount: loan.current_balance).positive? &&
        loan.repayment_schedule_active_on?(pay_date)
    end
    return if loans.empty?

    raise ArgumentError, "Clear the direct loan deduction and enter the payment under the named loan repayment (#{loans.map(&:name).join(', ')}). A direct amount does not update a tracked loan balance."
  end
end
