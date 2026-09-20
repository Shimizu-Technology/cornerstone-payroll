# frozen_string_literal: true

require "digest"

# Assembles the accountant-facing record for one committed payroll from the
# immutable paycheck values and the append-only payment/liability ledgers. It
# does not recalculate payroll and does not invent a general-ledger mapping.
class PayrollFinalRecordService
  class Error < StandardError; end

  SCHEMA_VERSION = "v1"

  def initialize(pay_period:)
    @pay_period = pay_period
  end

  def call
    raise Error, "The final payroll record is available after payroll is committed" unless pay_period.committed?

    payload = {
      schema_version: SCHEMA_VERSION,
      generated_at: Time.current.iso8601,
      company: {
        id: pay_period.company_id,
        name: pay_period.company.name
      },
      pay_period: pay_period_payload,
      official_payroll: official_payroll_payload,
      journal: journal_payload,
      employee_payments: employee_payment_payload,
      liabilities: liability_payload,
      ytd_reconciliation: ytd_payload,
      evidence: evidence_payload
    }
    payload[:completion] = completion_payload(payload)
    payload[:record_fingerprint] = fingerprint(payload.except(:generated_at, :record_fingerprint))
    payload
  end

  private

  attr_reader :pay_period

  def items
    @items ||= pay_period.payroll_items.not_voided.includes(
      :employee,
      :check_events,
      :check_reconciliation_events,
      :payroll_item_field_entries,
      payroll_item_deductions: :deduction_type
    ).order(:employee_id, :id).to_a
  end

  def pay_period_payload
    {
      id: pay_period.id,
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      pay_date: pay_period.pay_date,
      status: pay_period.status,
      correction_status: pay_period.correction_status,
      cycle: pay_period.cycle,
      run_purpose: pay_period.run_purpose,
      committed_at: pay_period.committed_at,
      committed_by_name: User.find_by(id: pay_period.committed_by_id)&.name
    }
  end

  def official_payroll_payload
    review = approved_review_package
    {
      status: pay_period.voided? ? "voided" : "official",
      paycheck_count: items.length,
      gross_pay: money(sum_items(&:gross_pay)),
      non_taxable_pay: money(sum_items { |item| non_taxable_pay(item) }),
      employee_deductions: money(sum_items(&:total_deductions)),
      net_pay: money(sum_items(&:net_pay)),
      employer_taxes: money(sum_items { |item| employer_taxes(item) }),
      employer_contributions: money(sum_items { |item| employer_contributions(item) }),
      total_payroll_cost: money(sum_items { |item| total_payroll_cost(item) }),
      client_approval_required: pay_period.company.client_payroll_approval_required?,
      approved_review_revision: review&.revision,
      calculation_checksum: review&.calculation_checksum
    }
  end

  def journal_payload
    gross = sum_items(&:gross_pay)
    non_taxable = sum_items { |item| non_taxable_pay(item) }
    employee_taxes = sum_items { |item| employee_taxes(item) }
    tips_paid_out = sum_items(&:tips_paid_out)
    loan_repayments = sum_items { |item| employee_loan_repayments(item) }
    other_employee_deductions = sum_items(&:total_deductions) - employee_taxes - tips_paid_out - loan_repayments
    employer_tax = sum_items { |item| employer_taxes(item) }
    employer_contribution = sum_items { |item| employer_contributions(item) }

    lines = [
      journal_line("gross_payroll_expense", "Gross payroll expense", debit: gross, source: "Committed gross pay"),
      journal_line("non_taxable_payroll_expense", "Non-taxable payroll additions", debit: non_taxable, source: "Committed non-taxable additions"),
      journal_line("employer_payroll_tax_expense", "Employer payroll tax expense", debit: employer_tax, source: "Committed employer Social Security and Medicare"),
      journal_line("employer_contribution_expense", "Employer contribution expense", debit: employer_contribution, source: "Committed employer contributions"),
      journal_line("net_payroll_payable", "Employee net payroll payable", credit: sum_items(&:net_pay), source: "Committed net pay"),
      journal_line("employee_tax_payable", "Employee payroll taxes withheld", credit: employee_taxes, source: "Committed employee tax withholding"),
      journal_line("employee_deduction_payable", "Other employee deductions payable", credit: other_employee_deductions, source: "Committed deductions excluding taxes, loans, and paid-out tips"),
      journal_line("employee_loan_receivable", "Employee loan repayments", credit: loan_repayments, source: "Committed employee loan deductions"),
      journal_line("tips_paid_clearing", "Tips already paid clearing", credit: tips_paid_out, source: "Committed tips paid before payroll"),
      journal_line("employer_tax_payable", "Employer payroll taxes payable", credit: employer_tax, source: "Committed employer Social Security and Medicare"),
      journal_line("employer_contribution_payable", "Employer contributions payable", credit: employer_contribution, source: "Committed employer contributions")
    ].reject { |line| line[:debit] == "0.0" && line[:credit] == "0.0" }
    debit_total = lines.sum(0.to_d) { |line| line[:debit].to_d }
    credit_total = lines.sum(0.to_d) { |line| line[:credit].to_d }
    difference = (debit_total - credit_total).round(2)

    {
      basis: "Committed paycheck values; reference categories are not a client general-ledger account mapping.",
      lines:,
      debit_total: money(debit_total),
      credit_total: money(credit_total),
      difference: money(difference),
      balanced: difference.zero?
    }
  end

  def journal_line(key, label, debit: 0, credit: 0, source:)
    signed_amount = debit.to_d - credit.to_d
    normalized_debit = signed_amount.positive? ? signed_amount : 0.to_d
    normalized_credit = signed_amount.negative? ? -signed_amount : 0.to_d
    { account_key: key, account_label: label, debit: money(normalized_debit), credit: money(normalized_credit), source: }
  end

  def employee_payment_payload
    payable_items = items.select { |item| item.net_pay.to_d.positive? }
    rows = payable_items.map do |item|
      direct_deposit = item.effective_payment_delivery_method == "direct_deposit"
      reconciliation_status = direct_deposit ? "not_tracked" : (item.check_number.present? ? CheckReconciliationStatus.for(item) : "not_assigned")
      {
        payroll_item_id: item.id,
        employee_id: item.employee_id,
        employee_name: item.employee.full_name,
        amount: money(item.net_pay),
        payment_delivery_method: item.effective_payment_delivery_method,
        check_number: item.check_number,
        issuance_status: direct_deposit ? "transfer_not_confirmed" : (item.check_status || "not_assigned"),
        reconciliation_status:
      }
    end
    check_rows = rows.reject { |row| row[:payment_delivery_method] == "direct_deposit" }
    status_counts = rows.group_by { |row| row[:reconciliation_status] }.transform_values(&:length)

    {
      required_count: check_rows.length,
      direct_deposit_count: rows.length - check_rows.length,
      assigned_count: check_rows.count { |row| row[:check_number].present? },
      printed_count: check_rows.count { |row| row[:issuance_status].in?(%w[printed delivered]) },
      delivered_count: check_rows.count { |row| row[:issuance_status] == "delivered" },
      reconciled_count: check_rows.count { |row| row[:reconciliation_status].in?(%w[cleared voided]) },
      outstanding_count: check_rows.count { |row| !row[:reconciliation_status].in?(%w[cleared voided]) },
      total_amount: money(rows.sum(0.to_d) { |row| row[:amount].to_d }),
      by_status: status_counts,
      rows:
    }
  end

  def liability_payload
    reconciliation = PayrollLiabilityReconciliationService.new(pay_period:).call
    center = PayrollLiabilityCenterService.new(
      company: pay_period.company,
      pay_period_id: pay_period.id,
      include_payments: false
    ).call
    obligations = center.fetch(:obligations)
    calculated = obligations.sum(0.to_d) { |row| row[:calculated_amount].to_d }
    prepared = obligations.sum(0.to_d) { |row| row[:prepared_amount].to_d }
    paid = obligations.sum(0.to_d) { |row| row[:paid_amount].to_d }

    {
      posting_status: reconciliation.fetch(:status),
      payment_tracking_status: reconciliation.fetch(:payment_tracking_status),
      calculated_amount: money(calculated),
      prepared_amount: money(prepared),
      paid_amount: money(paid),
      outstanding_amount: money(calculated - paid),
      unreserved_amount: money(calculated - prepared),
      unclassified_components: reconciliation.fetch(:unclassified_components),
      obligations: obligations.map { |row| money_payload(row) }
    }
  end

  def ytd_payload
    period = PayrollReportingPeriod.new(
      start_date: Date.new(pay_period.pay_date.year, 1, 1),
      end_date: pay_period.pay_date
    )
    native = PayrollItem.joins(:pay_period)
      .includes(:payroll_item_field_entries, payroll_item_deductions: :deduction_type)
      .not_voided
      .where(company_id: pay_period.company_id, pay_periods: {
        id: PayPeriod.reportable_committed.where(company_id: pay_period.company_id, pay_date: period.range).select(:id)
      }).to_a
    unified = UnifiedPayrollReporting.new(company_id: pay_period.company_id, period:)
    historical = unified.historical_paychecks
    adjustments = unified.historical_adjustments
    unlinked = unified.unlinked_historical_paychecks
    historical_rows = historical + adjustments
    bridge = unified.source_summary(
      native_items: native,
      historical_paychecks: historical,
      historical_adjustments: adjustments,
      excluded_unlinked_paychecks: unlinked
    ).fetch(:historical_ytd_bridge)
    historical_present = historical_rows.any? || unlinked.any?
    status = if unlinked.any?
      "attention_required"
    elsif historical_present && !bridge.fetch(:applied)
      "attention_required"
    else
      "reconciled"
    end

    {
      status:,
      basis: "Pay date",
      through_pay_date: pay_period.pay_date,
      cornerstone_payroll_count: native.map(&:pay_period_id).uniq.length,
      cornerstone_paycheck_count: native.length,
      quickbooks_paycheck_count: historical.length,
      historical_adjustment_count: adjustments.length,
      excluded_unlinked_paycheck_count: unlinked.length,
      historical_ytd_bridge: bridge,
      totals: {
        gross_pay: money(native.sum(0.to_d, &:gross_pay) + historical_rows.sum(0.to_d, &:gross_pay)),
        employee_taxes: money(native.sum(0.to_d) { |item| employee_taxes(item) } + historical_rows.sum(0.to_d, &:employee_taxes)),
        total_deductions: money(native.sum(0.to_d, &:total_deductions) + historical_rows.sum(0.to_d) { |row| row.pretax_deductions.to_d + row.employee_taxes.to_d + row.after_tax_deductions.to_d }),
        net_pay: money(native.sum(0.to_d, &:net_pay) + historical_rows.sum(0.to_d, &:net_pay)),
        employer_taxes: money(native.sum(0.to_d) { |item| employer_taxes(item) } + historical_rows.sum(0.to_d, &:employer_taxes)),
        employer_contributions: money(native.sum(0.to_d) { |item| employer_contributions(item) } + historical_rows.sum(0.to_d, &:employer_contributions))
      }
    }
  end

  def evidence_payload
    review = approved_review_package
    manifest = review&.source_manifest.presence || PayrollReview::CalculationSnapshot.new(pay_period:).call.fetch(:source_manifest)
    intake_packages = Array(manifest["payroll_intake_packages"])
    time_imports = Array(manifest["time_tracking_imports"])

    {
      payroll_approval: {
        approved_at: pay_period.approved_at,
        approved_by_name: User.find_by(id: pay_period.approved_by_id)&.name
      },
      client_approval_required: pay_period.company.client_payroll_approval_required?,
      review: review && {
        revision: review.revision,
        calculation_checksum: review.calculation_checksum,
        approved_at: review.approved_at,
        approved_by_name: review.approved_by&.name,
        approval_method: review.approval_method,
        approval_evidence_reference: review.approval_evidence_reference
      },
      source_packages: intake_packages.map do |package|
        {
          id: package["id"],
          source_type: package["source_type"],
          package_id: package["package_id"],
          revision: package["package_revision"],
          import_hash: package["import_hash"],
          documents: Array(package["documents"]).map { |document| document.slice("filename", "sha256", "source_role") }
        }
      end,
      time_tracking_imports: time_imports.map do |time_import|
        time_import.slice("id", "external_batch_id", "external_batch_checksum", "contract_version", "source_cutoff_at", "raw_payload_sha256", "processed_payload_sha256")
      end
    }
  end

  def completion_payload(payload)
    blockers = []
    open_items = []
    blockers << "This payroll has been voided" if pay_period.voided?
    blockers << "Payroll journal is out of balance" unless payload.dig(:journal, :balanced)
    if payload.dig(:evidence, :client_approval_required) && !payload.dig(:evidence, :review)
      blockers << "The required client-approved payroll review evidence is missing"
    end
    blockers << "Payroll liabilities have not been posted" if payload.dig(:liabilities, :posting_status) == "legacy_unposted"
    blockers << "Classify every payroll deduction liability" if payload.dig(:liabilities, :unclassified_components).any?
    blockers << "Resolve the historical YTD bridge" if payload.dig(:ytd_reconciliation, :status) == "attention_required"
    missing_checks = payload.dig(:employee_payments, :required_count) - payload.dig(:employee_payments, :assigned_count)
    blockers << "Assign #{missing_checks} employee check #{missing_checks == 1 ? 'number' : 'numbers'}" if missing_checks.positive?

    outstanding_checks = payload.dig(:employee_payments, :outstanding_count)
    open_items << "Reconcile #{outstanding_checks} employee #{outstanding_checks == 1 ? 'check' : 'checks'}" if outstanding_checks.positive?
    outstanding_liability = payload.dig(:liabilities, :outstanding_amount).to_d
    open_items << "Settle #{format_currency(outstanding_liability)} in payroll liabilities" if outstanding_liability.positive?

    status = if blockers.any?
      "attention_required"
    elsif open_items.any?
      "in_progress"
    else
      "complete"
    end
    { status:, blockers:, open_items: }
  end

  def approved_review_package
    @approved_review_package ||= pay_period.payroll_review_packages.current.where(status: "approved")
      .includes(:approved_by).order(revision: :desc).first
  end

  def employee_taxes(item)
    item.withholding_tax.to_d + item.additional_withholding.to_d + item.social_security_tax.to_d + item.medicare_tax.to_d
  end

  def employer_taxes(item)
    item.employer_social_security_tax.to_d + item.employer_medicare_tax.to_d
  end

  def employer_contributions(item)
    itemized = item.payroll_item_deductions.select(&:employer_contribution?).sum(0.to_d) { |deduction| deduction.amount.to_d }
    return itemized if itemized.nonzero?

    item.employer_retirement_match.to_d + item.employer_roth_retirement_match.to_d
  end

  def employee_loan_repayments(item)
    deductions = item.payroll_item_deductions.select do |deduction|
      deduction.post_tax? && (deduction.employee_loan_id.present? || deduction.deduction_type&.loan?)
    end
    return item.loan_deduction.to_d + deductions.sum(0.to_d) { |deduction| deduction.amount.to_d } if deductions.any?

    item.loan_deduction.to_d.nonzero? || item.loan_payment.to_d
  end

  def non_taxable_pay(item)
    return item.net_pay.to_d - item.gross_pay.to_d + item.total_deductions.to_d if item.correction_entry?

    item.non_taxable_pay.to_d + item.non_taxable_payroll_adjustments_total.to_d + item.non_taxable_payroll_field_entries_total.to_d
  end

  def total_payroll_cost(item)
    item.gross_pay.to_d + non_taxable_pay(item) + employer_taxes(item) + employer_contributions(item)
  end

  def sum_items(&)
    items.sum(0.to_d) { |item| yield(item).to_d }
  end

  def money(value)
    value.to_d.round(2).to_s("F")
  end

  def money_payload(row)
    row.transform_values { |value| value.is_a?(Float) || value.is_a?(BigDecimal) ? money(value) : value }
  end

  def format_currency(amount)
    "$#{format('%.2f', amount)}"
  end

  def fingerprint(payload)
    Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(payload)))
  end
end
