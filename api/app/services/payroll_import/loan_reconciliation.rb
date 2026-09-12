# frozen_string_literal: true

module PayrollImport
  class LoanReconciliation
    TOLERANCE = 0.01.to_d

    def initialize(employee:, pay_date:, source_row:)
      @employee = employee
      @pay_date = pay_date
      @source_row = source_row.to_h.symbolize_keys
      @errors = []
      @warnings = []
      @matches = []
    end

    def call
      recurring_amount = money(source_row[:recurring_loan_deduction])
      installment_payment = money(source_row[:installment_payment])
      one_payroll_amount = money(source_row[:one_payroll_deduction])
      source_total = money(source_row[:loan_deduction])
      classified_total = one_payroll_amount + recurring_amount + installment_payment

      reconcile_recurring!(recurring_amount) if recurring_amount.positive?
      reconcile_installment! if installment_source_present?

      unclassified = source_total - classified_total
      if unclassified.abs > TOLERANCE
        errors << "The workbook loan total includes #{currency(unclassified.abs)} that is not identified as recurring or installment. Correct the workbook before import."
      end

      {
        direct_loan_deduction: errors.empty? ? one_payroll_amount : source_total,
        errors: errors,
        warnings: warnings,
        matches: matches
      }
    end

    private

    attr_reader :employee, :pay_date, :source_row, :errors, :warnings, :matches

    def reconcile_recurring!(source_amount)
      loan = unique_active_loan("recurring_no_balance", "recurring deduction")
      return unless loan

      expected = scheduled_amount(loan)
      unless close?(source_amount, expected)
        errors << "#{loan.name} is #{currency(expected)} for this payday, but the workbook says #{currency(source_amount)}. Update the schedule in Cornerstone or correct the workbook."
        return
      end

      matches << match_payload(loan, source_amount)
    end

    def reconcile_installment!
      loan = unique_active_loan("balance_tracked", "installment loan")
      return unless loan

      beginning = money(source_row[:installment_beginning_balance])
      addition = money(source_row[:installment_new_amount])
      source_payment = money(source_row[:installment_payment])
      expected_current = beginning + addition
      if beginning <= 0
        errors << "#{loan.name} needs a beginning balance in the workbook."
        return
      end
      unless close?(loan.current_balance, expected_current)
        errors << "#{loan.name} has #{currency(loan.current_balance)} in Cornerstone, but the workbook implies #{currency(expected_current)} before this payment. Reconcile the balance first."
        return
      end

      expected_payment = scheduled_amount(loan)
      if close?(source_payment, expected_payment)
        # Exact match; the linked schedule will create the paycheck deduction.
      elsif expected_payment < loan.payment_amount.to_d && close?(source_payment, loan.payment_amount)
        warnings << "#{loan.name}'s final scheduled #{currency(source_payment)} payment will be capped to the remaining #{currency(expected_payment)} balance."
      else
        errors << "#{loan.name} is #{currency(expected_payment)} for this payday, but the workbook says #{currency(source_payment)}. Update the named schedule in Cornerstone or correct the workbook."
        return
      end

      expected_ending = (loan.current_balance.to_d - expected_payment).round(2)
      source_ending = money(source_row[:installment_estimated_ending_balance])
      if source_ending.positive? && !close?(source_ending, expected_ending)
        errors << "#{loan.name} should end at #{currency(expected_ending)}, but the workbook says #{currency(source_ending)}."
        return
      end
      if addition.positive?
        warnings << "The workbook includes a #{currency(addition)} advance for #{loan.name}; Cornerstone's verified balance already includes it and will not add it again."
      end

      matches << match_payload(loan, expected_payment)
    end

    def unique_active_loan(mode, label)
      candidates = employee.employee_loans.active.where(tracking_mode: mode).select do |loan|
        loan.repayment_schedule_active_on?(pay_date)
      end
      if candidates.empty?
        errors << "Set up the named #{label} for #{employee.full_name} in Employee Loans before importing this amount."
        return
      end
      if candidates.many?
        errors << "The workbook does not identify which #{label} belongs to #{employee.full_name}. Use the generated Cornerstone template with stable component IDs."
        return
      end

      candidates.first
    end

    def scheduled_amount(loan)
      loan.scheduled_payment_for(pay_date: pay_date, requested_amount: loan.payment_amount || 0).to_d
    end

    def installment_source_present?
      %i[installment_beginning_balance installment_new_amount installment_payment installment_estimated_ending_balance]
        .any? { |key| money(source_row[key]).positive? }
    end

    def match_payload(loan, amount)
      { employee_loan_id: loan.id, tracking_mode: loan.tracking_mode, name: loan.name, amount: amount.round(2) }
    end

    def close?(left, right)
      (left.to_d - right.to_d).abs <= TOLERANCE
    end

    def money(value)
      BigDecimal(value.to_s.presence || "0").round(2)
    rescue ArgumentError
      0.to_d
    end

    def currency(value)
      format("$%.2f", value.to_d)
    end
  end
end
