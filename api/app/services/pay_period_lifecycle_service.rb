# frozen_string_literal: true

# Owns state transitions that change whether a payroll run is editable or
# financially final. Every public operation locks and reloads the pay-period row
# before validating state. Child mutation/import paths acquire the same row lock
# first, so commit cannot observe or finalize a partially-mutated payroll.
class PayPeriodLifecycleService
  class Error < StandardError; end
  class InvalidTransitionError < Error; end
  class EmptyPayPeriodError < Error; end

  def initialize(pay_period:, actor:, ip_address: nil)
    @pay_period = pay_period
    @actor = actor
    @ip_address = ip_address
  end

  def approve!
    pay_period.with_lock do
      unless pay_period.calculated?
        raise InvalidTransitionError, "Can only approve a calculated pay period"
      end

      pay_period.update!(
        status: "approved",
        approved_by_id: actor&.id,
        approved_at: Time.current
      )
    end

    pay_period
  end

  def unapprove!
    pay_period.with_lock do
      unless pay_period.approved?
        raise InvalidTransitionError, "Can only unapprove an approved pay period"
      end

      pay_period.update!(
        status: "calculated",
        approved_by_id: nil,
        approved_at: nil,
        unapproved_at: Time.current,
        unapproved_by_id: actor&.id
      )
    end

    pay_period
  end

  def commit!
    pay_period.with_lock do
      unless pay_period.approved?
        raise InvalidTransitionError, "Can only commit an approved pay period"
      end
      unless pay_period.payroll_items.exists?
        raise EmptyPayPeriodError, "Cannot commit pay period with no payroll items"
      end

      pay_period.update!(
        status: "committed",
        committed_at: Time.current,
        committed_by_id: actor&.id
      )

      committed_items = pay_period.payroll_items.includes(
        :employee,
        payroll_item_deductions: :deduction_type,
        employee: { employee_loans: :loan_transactions }
      ).to_a

      apply_ytd_and_loan_effects!(committed_items)
      PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: actor)
      assign_check_numbers!(committed_items)
      create_fit_tax_deposit_check!(committed_items) if pay_period.company.auto_create_fit_check?
      tax_sync_enabled = pay_period.prepare_tax_sync_if_configured!
      record_correction_commit! if pay_period.correction_run?
      enqueue_tax_sync_after_commit if tax_sync_enabled
    end

    pay_period
  end

  private

  attr_reader :pay_period, :actor, :ip_address

  def apply_ytd_and_loan_effects!(committed_items)
    year = pay_period.pay_date.year
    employee_ids = committed_items.map(&:employee_id).uniq
    employee_ytds = EmployeeYtdTotal.where(employee_id: employee_ids, year: year).index_by(&:employee_id)
    employee_ids.each do |employee_id|
      employee_ytds[employee_id] ||= EmployeeYtdTotal.find_or_create_by!(employee_id: employee_id, year: year)
    end
    company_ytd = CompanyYtdTotal.find_or_create_by!(company_id: pay_period.company_id, year: year)

    committed_items.each do |item|
      PayrollCalculator.for(item.employee, item).apply_loan_payments!
      employee_ytds.fetch(item.employee_id).add_payroll_item!(item)
      company_ytd.add_payroll_item!(item)
    end
  end

  def assign_check_numbers!(committed_items)
    unassigned = committed_items.select { |item| item.check_number.nil? && item.net_pay.to_d.positive? }
    return if unassigned.empty?

    pay_period.company.assign_check_numbers!(unassigned)
    assigned_items = PayrollItem.where(id: unassigned.map(&:id)).where.not(check_number: nil).pluck(:id, :check_number)
    return if assigned_items.empty?

    now = Time.current
    actor_id = actor&.persisted? ? actor.id : nil
    CheckEvent.insert_all!(
      assigned_items.map do |item_id, check_number|
        {
          payroll_item_id: item_id,
          user_id: actor_id,
          event_type: "assigned",
          check_number: check_number,
          reason: "Assigned when pay period was committed",
          ip_address: ip_address,
          created_at: now,
          updated_at: now
        }
      end
    )
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("PayPeriodLifecycleService check assignment audit failed: #{e.message}")
    raise Error, "An error occurred recording check assignment audit events; the pay period commit was rolled back in full. Please retry committing this pay period."
  end

  def create_fit_tax_deposit_check!(items)
    return if NonEmployeeCheck.exists?(
      pay_period: pay_period,
      company_id: pay_period.company_id,
      auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
      voided: false
    )

    w2_items = items.reject { |item| item.employment_type == "contractor" || item.voided? }
    total_fit = w2_items.sum(&:total_income_tax_withheld)
    return unless total_fit.positive?

    NonEmployeeCheck.transaction(requires_new: true) do
      NonEmployeeCheck.create!(
        pay_period: pay_period,
        company_id: pay_period.company_id,
        payable_to: "Treasurer of Guam",
        amount: total_fit,
        check_number: pay_period.company.next_check_number!,
        check_type: "tax_deposit",
        auto_generated_type: NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
        payment_period_type: "pay_period",
        payment_date: pay_period.pay_date,
        memo: "FIT Withholding · PPE #{pay_period.end_date.strftime('%m/%d/%Y')} · Form 500",
        description: "Auto-generated Federal Income Tax deposit (remit to Guam DRT via Form 500)",
        created_by: actor
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # The unique-per-period index is a final idempotency backstop.
  end

  def record_correction_commit!
    PayPeriodCorrectionService.record_correction_committed!(
      pay_period: pay_period,
      actor: actor
    )
  end

  def enqueue_tax_sync_after_commit
    pay_period_id = pay_period.id
    ActiveRecord.after_all_transactions_commit do
      PayrollTaxSyncJob.perform_later(pay_period_id)
    end
  end
end
