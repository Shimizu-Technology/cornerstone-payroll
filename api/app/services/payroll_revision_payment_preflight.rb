# frozen_string_literal: true

# One conservative eligibility check shared by the read-only preview and the
# locked mutation. A paper package is not evidence that a check was delivered.
class PayrollRevisionPaymentPreflight
  attr_reader :pay_period, :employee_items, :other_payments

  def initialize(pay_period:, lock: false)
    @pay_period = pay_period
    @locked = lock
    items = pay_period.payroll_items.reportable.order(:id)
    @employee_items = (lock ? items.lock : items).to_a
    allocated_ids = PayrollLiabilityCheckAllocation.joins(payroll_liability_entry: :payroll_liability_posting)
      .where(payroll_liability_postings: { pay_period_id: pay_period.id }).select(:non_employee_check_id)
    payments = NonEmployeeCheck.where(pay_period_id: pay_period.id)
      .or(NonEmployeeCheck.where(id: allocated_ids)).order(:id)
    @other_payments = (lock ? payments.lock : payments).to_a
  end

  def call(reopen: false)
    blockers = []
    blockers << "Only a committed, active payroll can be reversed" unless pay_period.committed? && !pay_period.voided? && pay_period.superseded_by_id.nil?
    blockers << "Copied or promoted history must use the historical correction workflow" if pay_period.training_baseline? || pay_period.promotion_source_pay_period_id.present?
    employee_items.each do |item|
      if item.effective_payment_delivery_method == "direct_deposit" && item.net_pay.to_d.positive?
        blockers << "#{item.employee_full_name}: direct-deposit reversal is not supported; verify the external payment first"
      end
      delivered = item.check_events.where(check_number: item.check_number, event_type: "delivered").exists?
      reconciled = item.check_reconciliation_events.where(check_number: item.check_number).order(:created_at, :id).last
      if delivered || reconciled&.event_type.in?(%w[cleared replacement_required])
        blockers << "Employee check #{item.check_number} has issued or clearing evidence; use the paid-check correction workflow"
      end
    end
    other_payments.each do |payment|
      reconciled = payment.check_reconciliation_events.where(check_number: payment.check_number).order(:created_at, :id).last
      if payment.paid_at.present? || reconciled&.event_type.in?(%w[cleared replacement_required])
        blockers << "Payment #{payment.check_number || payment.id} to #{payment.payable_to} has payment or clearing evidence"
      end
      if payment.payment_method != "check"
        blockers << "Payment #{payment.id} uses #{payment.payment_method}; external payment reversal is not supported"
      end
      period_ids = payment.payroll_liability_check_allocations.joins(payroll_liability_entry: :payroll_liability_posting)
        .pluck("payroll_liability_postings.pay_period_id").uniq
      if period_ids.any? { |id| id != pay_period.id } || (payment.pay_period_id.present? && payment.pay_period_id != pay_period.id)
        blockers << "Payment #{payment.check_number || payment.id} covers another payroll; reconcile it separately"
      end
    end
    blockers << "This payroll has recorded paid or submitted tax filing evidence; use the filing correction workflow" if filing_evidence?
    if reopen
      if pay_period.time_tracking_imports.where(status: "applied").any?(&:finalized_batch?) ||
          TimeTrackingEntryAllocation.where(payroll_item_id: employee_items.map(&:id)).exists? ||
          TimeTrackingManualAllocation.where(payroll_item_id: employee_items.map(&:id)).exists?
        blockers << "This payroll has linked time-source processing evidence; use a reviewed source correction"
      end
      later = PayPeriod.reportable_committed.where(company_id: pay_period.company_id)
        .where.not(id: pay_period.id).where("pay_date > ? OR (pay_date = ? AND committed_at > ?)", pay_period.pay_date, pay_period.pay_date, pay_period.committed_at)
        .joins(:payroll_items).where(payroll_items: { employee_id: employee_items.map(&:employee_id) }).exists?
      blockers << "A later payroll for these employees is committed; review dependent totals before reopening" if later
      blockers << "This payroll has supplemental paycheck corrections; use the reviewed correction workflow" if pay_period.supplemental_pay_periods.exists? || employee_items.any?(&:correction_entry?)
    end
    {
      eligible: blockers.empty?, blockers: blockers.uniq, requires_unpaid_acknowledgement: true,
      employee_checks: employee_items.filter_map do |item|
        next unless item.check_number.present? || item.net_pay.to_d.positive?
        { id: item.id, check_number: item.check_number, payee: item.employee_full_name,
          amount: item.net_pay.to_f, status: item.check_status, already_voided: item.voided? }
      end,
      other_payments: other_payments.map do |payment|
        { id: payment.id, check_number: payment.check_number, payee: payment.payable_to,
          amount: payment.amount.to_f, status: payment.check_status, already_voided: payment.voided? }
      end
    }
  end

  def ensure_eligible!(reopen: false)
    result = call(reopen: reopen)
    raise PayPeriodCorrectionService::InvalidStateError, result[:blockers].join(". ") unless result[:eligible]
    @eligible_for_retirement = true
    self
  end

  def retirement_payment_ids
    unless @locked && @eligible_for_retirement
      raise PayPeriodCorrectionService::InvalidStateError, "Retirement requires a locked, successful payment preflight"
    end

    other_payments.reject(&:voided?).map(&:id)
  end

  def retire!(actor:, reason:)
    employee_items.each do |item|
      next if item.voided? || item.check_number.blank?
      item.void!(user: actor, reason: reason)
    end
    other_payments.each do |payment|
      next if payment.voided?
      payment.void!(reason: reason)
      AuditLog.record!(user: actor, company_id: pay_period.company_id,
        action: "void_non_employee_check", record_type: "NonEmployeeCheck", record_id: payment.id,
        metadata: { reason: reason, pay_period_id: pay_period.id, voided_at: payment.voided_at })
    end
  end

  private

  def filing_evidence?
    date = pay_period.pay_date
    quarter = (date.month - 1) / 3 + 1
    Form500Filing.where(pay_period_id: pay_period.id, status: %w[paid filed]).exists? ||
      PayrollFilingRecord.where(company_id: pay_period.company_id, tax_year: date.year)
        .where("quarter = ? OR quarter IS NULL", quarter).exists? ||
      QuarterlyComplianceTask.joins(:quarterly_compliance_packet)
        .where(quarterly_compliance_packets: { company_id: pay_period.company_id, year: date.year, quarter: quarter })
        .where("quarterly_compliance_tasks.paid_at IS NOT NULL OR quarterly_compliance_tasks.filed_at IS NOT NULL").exists?
  end
end
