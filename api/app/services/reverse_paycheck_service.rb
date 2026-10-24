# frozen_string_literal: true

# Explicit accounting reversal, independent of retiring a payment instrument.
# Connected source corrections continue through their reviewed correction flow.
class ReversePaycheckService
  def self.call(payroll_item:, actor:, reason:)
    new(payroll_item, actor, reason).call
  end

  def initialize(item, actor, reason)
    @item, @actor, @reason = item, actor, reason.to_s.strip
  end

  def call
    raise ArgumentError, "Reversal reason is required (minimum 10 characters)" if reason.length < 10

    TimeTracking::PaymentCancellationBridge.with_item_lock(item.id) do
      ApplicationRecord.transaction do
        company = Company.lock.find(item.company_id)
        period = PayPeriod.lock.find(item.pay_period_id)
        item.lock!
        raise ArgumentError, "This paycheck has already been reversed" unless item.payroll_included?
        raise ArgumentError, "Only a committed paycheck can be reversed" unless period.committed?
        raise ArgumentError, "Review the linked source accounting correction before reversing this paycheck" if item.source_accounting_correction_linked?
        raise ArgumentError, "Review the duplicate check reconciliation before reversing this paycheck" if item.duplicate_check_linked?
        if item.correction_entry? || item.correction_payroll_items.joins(:pay_period).merge(PayPeriod.reportable_committed).exists?
          raise ArgumentError, "This paycheck has supplemental corrections; use the reviewed payroll correction workflow"
        end
        if item.time_tracking_entry_allocations.exists? || item.time_tracking_manual_allocations.exists? || item.time_tracking_financial_correction_links.exists?
          raise ArgumentError, "This paycheck reserves connected source hours; use the reviewed source correction workflow"
        end
        # Filing, bank payment, clearing and liability-payment guards are shared
        # with whole-payroll reversal. Conservative period-wide preflight avoids
        # invalidating an already paid or filed shared obligation.
        payments = PayrollRevisionPaymentPreflight.new(pay_period: period, lock: true).ensure_eligible!
        if payments.other_payments.any? { |payment| !payment.voided? }
          raise ArgumentError, "This payroll has shared liability payments; reconcile them before reversing one paycheck"
        end
        PayrollLiabilityPaymentGuard.ensure_clear!(pay_period: period,
          error_class: ArgumentError, action: "reversing this paycheck", retirement_preflight: payments)

        year = period.pay_date.year
        employee_ytd = EmployeeYtdTotal.lock.find_by(employee_id: item.employee_id, year: year)
        company_ytd = CompanyYtdTotal.lock.find_by(company: company, year: year)
        unless employee_ytd && company_ytd && item.legacy_disposition.nil?
          raise ArgumentError, "Review the historical payroll and YTD ledgers before reversing this paycheck"
        end
        # Capture legacy liabilities before recording the item offset. Period
        # reversal later reverses both the original posting and this offset.
        PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) unless period.payroll_liability_postings.exists?
        reverse_liabilities!(period)
        item.void!(user: actor, reason: reason) if item.check_number.present? && !item.voided?
        employee_ytd.subtract_payroll_item!(item)
        company_ytd.subtract_payroll_item!(item)
        LoanTransaction.payments.where(payroll_item_id: item.id, source: "payroll").order(:employee_loan_id, :id).each do |payment|
          payment.employee_loan.reverse_payroll_payment!(payment, actor: actor, reason: reason)
        end
        item.update!(payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: reason)
        PayrollYtdSnapshotRefresh.call(pay_period: period, employee_ids: [ item.employee_id ])
        AuditLog.record!(user: actor, company_id: company.id, action: "payroll_item#reversed",
          record_type: "PayrollItem", record_id: item.id, subject_name: item.employee_full_name,
          metadata: { reason: reason, pay_period_id: period.id, gross_pay: item.gross_pay, net_pay: item.net_pay })
        if period.prepare_tax_sync_if_configured!
          period.update!(tax_sync_idempotency_key: "cpr-#{period.id}-paycheck-reversal-#{SecureRandom.uuid}")
          ActiveRecord.after_all_transactions_commit { PayrollTaxSyncJob.perform_later(period.id) }
        end
        item
      end
    end
  rescue PayPeriodCorrectionService::CorrectionError => e
    raise ArgumentError, e.message
  end

  private

  attr_reader :item, :actor, :reason

  def reverse_liabilities!(period)
    entries = period.payroll_liability_postings.joins(:entries)
      .where(payroll_liability_entries: { payroll_item_id: item.id })

    posting = PayrollLiabilityPosting.create!(company: period.company, pay_period: period,
      posting_type: "paycheck_reversal", liability_date: period.pay_date, posted_at: Time.current,
      posted_by: actor, reason: reason, idempotency_key: "payroll-item:#{item.id}:reverse",
      metadata: { payroll_item_id: item.id })
    # Net every existing journal entry, including prior pay-date restatements.
    rows = PayrollLiabilityEntry.where(payroll_liability_posting_id: entries.select(:id), payroll_item_id: item.id).map do |entry|
      entry.attributes.except("id", "created_at", "updated_at").merge(
        "payroll_liability_posting_id" => posting.id, "amount" => -entry.amount,
        "metadata" => entry.metadata.merge("reverses_entry_id" => entry.id),
        "created_at" => Time.current, "updated_at" => Time.current
      )
    end
    PayrollLiabilityEntry.insert_all!(rows) if rows.any?
  end
end
