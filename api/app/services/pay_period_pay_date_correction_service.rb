# frozen_string_literal: true

# Corrects the pay date on an already-committed payroll run without changing
# payroll dollars. This is for clerical date mistakes discovered after checks
# or stubs have been issued.
class PayPeriodPayDateCorrectionService
  class Error < StandardError; end

  Result = Struct.new(
    :pay_period,
    :old_pay_date,
    :new_pay_date,
    :payroll_items_updated,
    :non_employee_checks_updated,
    :noop,
    keyword_init: true
  )

  def self.call(...)
    new(...).call
  end

  def initialize(pay_period:, new_pay_date:, reason:)
    @pay_period = pay_period
    @new_pay_date = parse_date(new_pay_date)
    @reason = reason.to_s.strip
  end

  def call
    raise Error, "A reason is required to correct a committed pay date" if reason.blank?

    result = nil

    ActiveRecord::Base.transaction do
      locked = PayPeriod.lock("FOR UPDATE").find(pay_period.id)
      old_pay_date = locked.pay_date

      validate!(locked, old_pay_date)

      if new_pay_date == old_pay_date
        result = Result.new(
          pay_period: locked,
          old_pay_date: old_pay_date,
          new_pay_date: new_pay_date,
          payroll_items_updated: 0,
          non_employee_checks_updated: 0,
          noop: true
        )
        next
      end

      locked.update!(
        pay_date: new_pay_date,
        **locked.tax_sync_refresh_attributes
      )

      payroll_items_updated = locked.payroll_items.where(check_date: old_pay_date).update_all(
        check_date: new_pay_date,
        updated_at: Time.current
      )
      non_employee_checks_updated = locked.non_employee_checks.where(payment_date: old_pay_date).update_all(
        payment_date: new_pay_date,
        updated_at: Time.current
      )

      refresh_affected_ytd_snapshots!(locked, old_pay_date)

      result = Result.new(
        pay_period: locked,
        old_pay_date: old_pay_date,
        new_pay_date: new_pay_date,
        payroll_items_updated: payroll_items_updated,
        non_employee_checks_updated: non_employee_checks_updated,
        noop: false
      )

      if PayrollTaxSyncService.configured?
        ActiveRecord.after_all_transactions_commit do
          PayrollTaxSyncJob.perform_later(locked.id)
        end
      end
    end

    result
  end

  private

  attr_reader :pay_period, :new_pay_date, :reason

  def parse_date(value)
    return value if value.is_a?(Date)
    raise Error, "pay_date is required" if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise Error, "pay_date must be a valid YYYY-MM-DD date"
  end

  def validate!(locked, old_pay_date)
    raise Error, "Only committed pay periods can have a committed pay date correction" unless locked.committed?
    raise Error, "Cannot correct the pay date on a voided pay period" if locked.voided?
    raise Error, "Pay date must be on or after end date" if new_pay_date < locked.end_date

    if new_pay_date.year != old_pay_date.year
      raise Error, "Committed pay date corrections must stay in the same tax year"
    end
  end

  def refresh_affected_ytd_snapshots!(locked, old_pay_date)
    lower_bound = [ old_pay_date, locked.pay_date ].min

    affected_period_ids = PayPeriod.reportable_committed
                                   .where(company_id: locked.company_id)
                                   .where(pay_date: lower_bound..Date.new(locked.pay_date.year, 12, 31))
                                   .pluck(:id)

    PayrollItem.includes(:employee, :pay_period)
               .where(pay_period_id: affected_period_ids, voided: false)
               .find_each do |item|
      period = item.pay_period
      ytd = item.employee.ytd_totals_before(
        year: period.pay_date.year,
        pay_date: period.pay_date,
        pay_period_id: period.id
      )

      item.update_columns(
        ytd_gross: ytd[:gross_pay].to_d + item.gross_pay.to_d,
        ytd_net: ytd[:net_pay].to_d + item.net_pay.to_d,
        ytd_withholding_tax: ytd[:withholding_tax].to_d + item.withholding_tax.to_d,
        ytd_social_security_tax: ytd[:social_security_tax].to_d + item.social_security_tax.to_d,
        ytd_medicare_tax: ytd[:medicare_tax].to_d + item.medicare_tax.to_d,
        ytd_retirement: ytd[:retirement].to_d + item.retirement_payment.to_d,
        ytd_roth_retirement: ytd[:roth_retirement].to_d + item.roth_retirement_payment.to_d,
        updated_at: Time.current
      )
    end
  end
end
