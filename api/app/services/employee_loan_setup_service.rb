# frozen_string_literal: true

# Creates a named Employee Loan and its repayment schedule. The Employee Loans
# screen and payroll import review both use it, so a loan set up from either
# place follows the same balance, schedule and linking rules.
class EmployeeLoanSetupService
  def self.recurring_loan_adjustment?(adjustment)
    adjustment["active"] != false && adjustment["treatment"] == "post_tax_deduction" && adjustment["label"].match?(/\bloan\b/i)
  end

  def self.adjustment_fingerprint(adjustment)
    Digest::SHA256.hexdigest(adjustment.to_json)
  end

  def initialize(company:, actor:)
    @company = company
    @actor = actor
  end

  # attributes: loan columns (company-scoped deduction_type_id already checked).
  # Raises ArgumentError, ActiveRecord::RecordInvalid or RecordNotUnique.
  def create!(employee:, attributes:, setup_mode: "new_loan", schedule_kind: nil, schedule_id: nil, schedule_fingerprint: nil)
    raise ArgumentError, "Employee must belong to this client" unless employee.company_id == company.id

    attributes = attributes.to_h.symbolize_keys
    schedule = resolve_schedule(employee, kind: schedule_kind, id: schedule_id, fingerprint: schedule_fingerprint) unless schedule_kind == "new"
    attributes[:payment_amount] ||= schedule[:data]["amount"] if schedule.is_a?(Hash)
    attributes[:payment_amount] ||= schedule.effective_amount_for(0) if schedule.is_a?(EmployeePayrollField)
    attributes[:payment_amount] ||= schedule.amount if schedule.is_a?(EmployeeDeduction)
    attributes[:deduction_type_id] = schedule.deduction_type_id if schedule.is_a?(EmployeeDeduction)
    if attributes[:tracking_mode] == "recurring_no_balance"
      configure_recurring_deduction!(attributes, schedule_kind: schedule_kind)
    else
      attributes[:tracking_mode] = "balance_tracked"
      configure_opening_balance!(attributes, setup_mode: setup_mode)
    end

    loan = EmployeeLoan.new(attributes)
    loan.company_id = company.id
    loan.employee = employee
    loan.created_by = actor

    ActiveRecord::Base.transaction do
      employee.lock!
      schedule = resolve_schedule(employee, kind: schedule_kind, id: schedule_id, fingerprint: schedule_fingerprint) unless schedule_kind == "new"
      loan.save!

      if loan.balance_tracked?
        loan.loan_transactions.create!(
          transaction_type: "addition",
          amount: loan.opening_balance,
          balance_before: 0,
          balance_after: loan.opening_balance,
          transaction_date: loan.balance_as_of,
          notes: setup_mode == "existing_balance" ? "Verified opening balance" : "Initial loan",
          source: "opening_balance",
          recorded_by: actor
        )
      end
      configure_repayment_schedule!(loan, schedule: schedule, create_new: schedule_kind == "new")
    end

    loan
  end

  private

  attr_reader :company, :actor

  def configure_opening_balance!(attributes, setup_mode:)
    unless setup_mode.in?(%w[new_loan existing_balance])
      raise ArgumentError, "Balance setup mode is invalid"
    end

    if setup_mode == "existing_balance"
      opening_balance = BigDecimal(attributes[:opening_balance].to_s, exception: false)
      raise ArgumentError, "Confirmed opening balance must be greater than zero" unless opening_balance&.positive?
      raise ArgumentError, "Balance as-of date is required" if attributes[:balance_as_of].blank?
      unless attributes[:balance_source].to_s.in?(EmployeeLoan::BALANCE_SOURCES - [ "new_loan" ])
        raise ArgumentError, "Choose where the opening balance was verified"
      end

      principal_known = ActiveModel::Type::Boolean.new.cast(attributes[:principal_amount_known]) == true
      attributes[:opening_balance] = opening_balance
      attributes[:current_balance] = opening_balance
      if principal_known
        original_amount = BigDecimal(attributes[:original_amount].to_s, exception: false)
        raise ArgumentError, "Original principal must be greater than zero" unless original_amount&.positive?

        attributes[:original_amount] = original_amount
      else
        # Keep the legacy non-null column usable without presenting the confirmed
        # balance as a known original principal in the product.
        attributes[:original_amount] = opening_balance
      end
      attributes[:principal_amount_known] = principal_known
    else
      original_amount = BigDecimal(attributes[:original_amount].to_s, exception: false)
      raise ArgumentError, "Original amount must be greater than zero" unless original_amount&.positive?

      attributes[:opening_balance] = original_amount
      attributes[:current_balance] = original_amount
      attributes[:balance_as_of] = attributes[:start_date].presence || Date.current
      attributes[:balance_source] = "new_loan"
      attributes[:principal_amount_known] = true
    end
  rescue ArgumentError => e
    raise e if e.message.match?(/Balance|Confirmed|Original|Choose/)

    raise ArgumentError, "Enter a valid opening balance"
  end

  def configure_recurring_deduction!(attributes, schedule_kind:)
    raise ArgumentError, "Choose or create a payroll deduction schedule" if schedule_kind.blank?

    payment_amount = BigDecimal(attributes[:payment_amount].to_s, exception: false)
    raise ArgumentError, "Payment per payday must be greater than zero" unless payment_amount&.positive?
    raise ArgumentError, "First deduction payday is required" if attributes[:first_deduction_date].blank?

    attributes[:payment_amount] = payment_amount
    attributes[:original_amount] = nil
    attributes[:opening_balance] = nil
    attributes[:current_balance] = nil
    attributes[:balance_as_of] = nil
    attributes[:balance_source] = nil
    attributes[:principal_amount_known] = false
  end

  def resolve_schedule(employee, kind:, id:, fingerprint: nil)
    return if kind.blank? && id.blank?

    case kind
    when "recurring_adjustment"
      index = Integer(id.to_s, 10) - 1
      adjustment = Employee.normalize_payroll_adjustments(employee.default_payroll_adjustments)[index] if index >= 0
      unless adjustment && self.class.recurring_loan_adjustment?(adjustment) && self.class.adjustment_fingerprint(adjustment) == fingerprint
        raise ArgumentError, "Recurring loan setup changed; reload Loans before linking its verified balance"
      end
      ensure_recurring_paychecks_can_refresh!(employee, adjustment)
      { index: index, data: adjustment }
    when "employee_deduction"
      schedule = employee.employee_deductions.active.joins(:deduction_type)
        .where(deduction_types: { company_id: company.id, sub_category: "loan", active: true })
        .find_by(id: id) || raise(ArgumentError, "Loan deduction schedule not found")
      if employee.employee_loans.exists?(deduction_type_id: schedule.deduction_type_id)
        raise ArgumentError, "This deduction schedule already has a named loan or recurring-deduction ledger"
      end
      schedule
    when "payroll_field"
      schedule = employee.employee_payroll_fields.active.joins(:payroll_field_definition)
        .where(payroll_field_definitions: { company_id: company.id, kind: "deduction", category: "loan", active: true })
        .find_by(id: id) || raise(ArgumentError, "Loan payroll field schedule not found")
      if schedule.employee_loan.present?
        raise ArgumentError, "This payroll field already has a named loan or recurring-deduction ledger"
      end
      schedule
    else
      raise ArgumentError, "Loan deduction schedule is invalid"
    end
  end

  def configure_repayment_schedule!(loan, schedule:, create_new:)
    if create_new || schedule.is_a?(Hash)
      raise ArgumentError, "Enter a payment per payday and first deduction payday" unless loan.payment_amount&.positive? && loan.first_deduction_date

      deduction_type = loan.company.deduction_types.create!(
        name: "#{loan.name} (loan #{loan.id})", category: "post_tax", sub_category: "loan", active: true
      )
      loan.update!(deduction_type: deduction_type)
      if schedule.is_a?(Hash)
        adjustments = Employee.normalize_payroll_adjustments(loan.employee.default_payroll_adjustments)
        adjustments[schedule[:index]]["active"] = false
        loan.employee.update!(default_payroll_adjustments: adjustments)
        AuditLog.record!(user: actor, company_id: loan.company_id,
          action: "employee_loans#replace_recurring_deduction", record_type: "employees", record_id: loan.employee_id,
          subject_name: loan.employee.full_name, metadata: { loan_id: loan.id, previous_adjustment: schedule[:data], first_deduction_date: loan.first_deduction_date, payment_amount: loan.payment_amount })
      end
      schedule = loan.employee.employee_deductions.create!(deduction_type: deduction_type, amount: loan.payment_amount, active: true, is_percentage: false)
    end
    if schedule.is_a?(EmployeePayrollField)
      raise ArgumentError, "A named loan or recurring deduction must use a fixed, post-tax payroll deduction" unless schedule.amount_type == "fixed" && schedule.tax_treatment == "post_tax_deduction"

      schedule.update!(employee_loan: loan, amount: loan.payment_amount || schedule.amount)
    elsif schedule.is_a?(EmployeeDeduction)
      raise ArgumentError, "A named loan or recurring deduction must use a fixed, post-tax payroll deduction" unless schedule.post_tax? && !schedule.is_percentage?

      schedule.update!(amount: loan.payment_amount || schedule.amount)
    end
  end

  def ensure_recurring_paychecks_can_refresh!(employee, adjustment)
    employee.payroll_items.joins(:pay_period).where(pay_periods: { status: %w[draft calculated approved] }).each do |item|
      includes_old_deduction = item.active_payroll_adjustments.any? do |entry|
        entry["label"] == adjustment["label"] && entry["treatment"] == adjustment["treatment"]
      end
      next unless includes_old_deduction
      next if !item.pay_period.approved? && item.payroll_adjustments_default_snapshot? && !item.payroll_adjustments_overridden?

      raise ArgumentError, "Payroll #{item.pay_period_id} already includes this loan in saved adjustments. Remove that old deduction from the editable paycheck (unapprove first if needed), then link the verified balance and recalculate"
    end
  end
end
