# frozen_string_literal: true

# A direct amount has no loan identity. It must not replace a scheduled payment
# whose balance needs to move when this paycheck is committed.
class PayrollLoanConfigurationGuard
  def self.validate!(employee:, payroll_item:)
    return unless payroll_item.loan_deduction.to_d.positive?

    pay_date = payroll_item.pay_period.pay_date
    loans = employee.employee_loans.includes(employee_payroll_fields: :payroll_field_definition).select do |loan|
      next false unless loan.scheduled_payment_for(pay_date: pay_date, requested_amount: loan.current_balance).positive?

      fields = loan.employee_payroll_fields
      if fields.any?
        fields.any? do |assignment|
          assignment.active? && assignment.payroll_field_definition.active? &&
            (assignment.start_date.blank? || assignment.start_date <= pay_date) &&
            (assignment.end_date.blank? || assignment.end_date >= pay_date)
        end
      elsif loan.deduction_type&.active?
        employee.employee_deductions.active.exists?(deduction_type_id: loan.deduction_type_id)
      end
    end
    return if loans.empty?

    raise ArgumentError, "Clear the direct loan deduction and enter the payment under the named loan repayment (#{loans.map(&:name).join(', ')}). A direct amount does not update a tracked loan balance."
  end
end
