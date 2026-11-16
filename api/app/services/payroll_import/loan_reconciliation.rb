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
      @installment_setup = nil
    end

    def call
      recurring_amount = money(source_row[:recurring_loan_deduction])
      installment_payment = money(source_row[:installment_payment])
      one_payroll_amount = money(source_row[:one_payroll_deduction])
      source_total = money(source_row[:loan_deduction])
      classified_total = one_payroll_amount + recurring_amount + installment_payment

      direct_amount = one_payroll_amount
      if recurring_amount.positive?
        # One-time or varying loans (MoSa's LOANS (NO INSTALLMENTS) tab) have no
        # Employee Loans record; deduct them as entered. A set-up or paused
        # ledger still reconciles so its deduction is never taken twice.
        if open_recurring_loans.none?
          direct_amount += recurring_amount
        else
          reconcile_recurring!(recurring_amount)
        end
      end
      reconcile_installment! if installment_source_present?

      unclassified = source_total - classified_total
      if unclassified.abs > TOLERANCE
        errors << "The workbook loan total includes #{currency(unclassified.abs)} that is not identified as recurring or installment. Correct the workbook before import."
      end

      {
        direct_loan_deduction: errors.empty? ? direct_amount : source_total,
        errors: errors,
        warnings: warnings,
        matches: matches,
        # What import review offers when the workbook has an installment the
        # Employee Loans ledger doesn't: set it up, or resume a paused one.
        installment_setup: @installment_setup
      }
    end

    private

    attr_reader :employee, :pay_date, :source_row, :errors, :warnings, :matches

    def reconcile_recurring!(source_amount)
      if active_loans("recurring_no_balance").empty?
        names = open_recurring_loans.map(&:name).to_sentence
        errors << "#{names} is paused or not scheduled for this payday in Employee Loans, but the workbook says #{currency(source_amount)}. Resume the deduction or correct the workbook."
        return
      end

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
      if active_loans("balance_tracked").empty?
        offer_installment_setup!
        return
      end
      loan = unique_active_loan("balance_tracked", "installment loan")
      return unless loan

      beginning = money(source_row[:installment_beginning_balance])
      addition = money(source_row[:installment_new_amount])
      source_payment = money(source_row[:installment_payment])
      expected_current = beginning + addition
      # A new loan can arrive as a new amount on a zero beginning balance.
      if expected_current <= 0
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

    # No active installment loan is scheduled for this payday. Offer the setup
    # only when the workbook row is unambiguous; never guess between loans.
    def offer_installment_setup!
      name = employee.full_name
      open_loans = employee.employee_loans.where(tracking_mode: "balance_tracked", status: %w[active suspended]).order(:id).to_a
      scheduled_elsewhere = open_loans.select(&:active?)
      paused = open_loans.reject(&:active?)
      if scheduled_elsewhere.any?
        errors << "#{scheduled_elsewhere.map(&:name).to_sentence} for #{name} isn't scheduled for this payday in Employee Loans. Check its first deduction date and schedule, or correct the workbook."
        return
      end
      if paused.many?
        errors << "#{name} has #{paused.length} paused installment loans in Employee Loans. Resume the right one there, then match the files again."
        return
      end
      if paused.one?
        loan = paused.first
        message = "#{loan.name} for #{name} is paused in Employee Loans. Resume it so this payroll deducts the installment."
        @installment_setup = { action: "resume", employee_loan_id: loan.id, name: loan.name,
          current_balance: loan.current_balance.to_d.round(2).to_s("F"), payment_amount: loan.payment_amount&.to_d&.round(2)&.to_s("F"), message: message }
        errors << message
        return
      end

      # A balance continuing on the workbook after Cornerstone closed the loan
      # (for example a capped final payment) is not a new debt.
      beginning = money(source_row[:installment_beginning_balance])
      paid_off = beginning.positive? && employee.employee_loans.where(tracking_mode: "balance_tracked", status: "paid_off").order(:paid_off_date, :id).last
      if paid_off
        paid_on = paid_off.paid_off_date ? " on #{paid_off.paid_off_date.strftime('%-m/%-d/%Y')}" : ""
        errors << "#{name}'s installment loan #{paid_off.name} was paid off#{paid_on} in Employee Loans, but the workbook still shows #{currency(beginning)}. Check the workbook with the client."
        return
      end

      row_count = source_row[:installment_row_count].to_i
      if row_count > 1
        errors << "The workbook has #{row_count} installment loan rows for #{name}. Ask the client to combine them into one row, or set up the loans in Employee Loans."
        return
      end
      addition = money(source_row[:installment_new_amount])
      payment = money(source_row[:installment_payment])
      starting = beginning + addition
      unless starting.positive? && payment.positive? && payment <= starting
        errors << "Set up the named installment loan for #{name} in Employee Loans before importing this amount."
        return
      end

      message = "The workbook has an installment loan for #{name} (#{currency(starting)} balance, #{currency(payment)} this payroll), but Employee Loans has none. Set it up so this payroll and later ones deduct it."
      @installment_setup = {
        action: "create", name: "Installment loan",
        starting_balance: starting.to_s("F"), payment_amount: payment.to_s("F"), first_deduction_date: pay_date.iso8601,
        beginning_balance: beginning.to_s("F"), new_amount: addition.to_s("F"),
        estimated_ending_balance: money(source_row[:installment_estimated_ending_balance]).to_s("F"), message: message
      }
      errors << message
    end

    def active_loans(mode)
      employee.employee_loans.active.where(tracking_mode: mode).select do |loan|
        loan.repayment_schedule_active_on?(pay_date)
      end
    end

    def open_recurring_loans
      employee.employee_loans.where(tracking_mode: "recurring_no_balance", status: %w[active suspended])
    end

    def unique_active_loan(mode, label)
      candidates = active_loans(mode)
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
