# frozen_string_literal: true

class PayrollLiabilityReconciliationService
  def initialize(pay_period:)
    @pay_period = pay_period
  end

  def call
    postings = pay_period.payroll_liability_postings
      .includes(:posted_by, entries: [ :payroll_item, :pay_component_tax_rule ])
      .chronological
      .to_a
    entries = postings.flat_map(&:entries)
    payments = pay_period.payroll_liability_payments
      .includes(:recorded_by, :source_payment, :reversal_payment, :allocations, evidence: :created_by)
      .chronological
      .to_a
    obligations = obligation_rows(postings, payments)
    settled_amount = payments.sum { |payment| payment.amount.to_d }.round(2)
    active_liability = obligations.sum { |obligation| obligation.fetch(:calculated_amount).to_d }.round(2)
    outstanding_amount = (active_liability - settled_amount).round(2)

    {
      status: reconciliation_status(postings),
      pay_period_id: pay_period.id,
      company_id: pay_period.company_id,
      liability_date: pay_period.pay_date,
      net_liability: entries.sum { |entry| entry.amount.to_d }.round(2).to_f,
      totals_by_category: grouped_totals(entries, &:category),
      totals_by_authority: grouped_totals(entries, &:authority),
      active_liability: active_liability.to_f,
      settled_amount: settled_amount.to_f,
      outstanding_amount: outstanding_amount.to_f,
      overdue_amount: obligations.select { |row| row[:status] == "overdue" }.sum { |row| row[:outstanding_amount].to_d }.round(2).to_f,
      obligations:,
      payments: payments.reverse.map { |payment| payment_json(payment) },
      postings: postings.map { |posting| posting_json(posting) },
      unclassified_components: unclassified_components,
      payment_tracking_status: payment_tracking_status(obligations, payments),
      historical_backfill_required: pay_period.committed? && postings.empty?
    }
  end

  private

  attr_reader :pay_period

  def reconciliation_status(postings)
    return "not_applicable" unless pay_period.committed?
    return "legacy_unposted" if postings.empty?
    return "reversed" if pay_period.voided? && net_amount(postings).zero?
    return "attention_required" if unclassified_components.any?

    "posted"
  end

  def net_amount(postings)
    postings.sum { |posting| posting.entries.sum { |entry| entry.amount.to_d } }.round(2)
  end

  def grouped_totals(entries)
    entries.group_by { |entry| yield(entry) }
      .transform_values { |group| group.sum { |entry| entry.amount.to_d }.round(2).to_f }
      .reject { |_key, amount| amount.zero? }
      .sort.to_h
  end

  def obligation_rows(postings, payments)
    active_postings = postings.reject(&:reversal?).reject(&:reversed?)
    groups = active_postings.flat_map(&:entries).group_by { |entry| [ entry.authority, entry.category ] }
    allocated_by_group = payments.group_by { |payment| [ payment.authority, payment.category ] }
      .transform_values { |group| group.sum { |payment| payment.amount.to_d }.round(2) }
    group_keys = (groups.keys + allocated_by_group.keys).uniq

    group_keys.map do |authority, category|
      group = groups.fetch([ authority, category ], [])
      calculated = group.sum { |entry| entry.amount.to_d }.round(2)
      settled = allocated_by_group.fetch([ authority, category ], 0.to_d)
      outstanding = (calculated - settled).round(2)
      due_date = due_date_for(authority, category)
      {
        authority:,
        category:,
        calculated_amount: calculated.to_f,
        settled_amount: settled.to_f,
        outstanding_amount: outstanding.to_f,
        due_date: due_date,
        status: obligation_status(calculated:, settled:, outstanding:, due_date:),
        entry_count: group.size
      }
    end.sort_by { |row| [ row[:due_date] || Date.new(9999, 12, 31), row[:authority], row[:category] ] }
  end

  def due_date_for(authority, category)
    due_dates.fetch([ authority, category ], nil)
  end

  def due_dates
    @due_dates ||= pay_period.payroll_liability_due_dates
      .pluck(:authority, :category, :due_date)
      .to_h { |authority, category, due_date| [ [ authority, category ], due_date ] }
  end

  def obligation_status(calculated:, settled:, outstanding:, due_date:)
    return "overpaid" if outstanding.negative?
    return "paid" if calculated.positive? && outstanding.zero?
    return "overdue" if outstanding.positive? && due_date && due_date < Date.current
    return "due" if outstanding.positive? && due_date && due_date == Date.current
    return "partially_paid" if settled.positive?

    "unpaid"
  end

  def payment_tracking_status(obligations, payments)
    return "not_applicable" if obligations.empty?
    return "unpaid" if payments.empty?
    return "overpaid" if obligations.any? { |row| row[:status] == "overpaid" }
    return "paid" if obligations.all? { |row| row[:status] == "paid" }
    return "overdue" if obligations.any? { |row| row[:status] == "overdue" }

    "partially_paid"
  end

  def payment_json(payment)
    {
      id: payment.id,
      payment_type: payment.payment_type,
      source_payment_id: payment.source_payment_id,
      reversed: payment.reversed?,
      authority: payment.authority,
      category: payment.category,
      amount: payment.amount.to_f,
      payment_date: payment.payment_date,
      payment_method: payment.payment_method,
      confirmation_number: payment.confirmation_number,
      notes: payment.notes,
      reason: payment.reason,
      recorded_at: payment.recorded_at,
      recorded_by_id: payment.recorded_by_id,
      recorded_by_name: payment.recorded_by&.name,
      evidence: payment.evidence.sort_by(&:created_at).map do |record|
        {
          id: record.id,
          filename: record.filename,
          content_type: record.content_type,
          byte_size: record.byte_size,
          sha256: record.sha256,
          created_at: record.created_at,
          created_by_name: record.created_by&.name
        }
      end
    }
  end

  def posting_json(posting)
    {
      id: posting.id,
      posting_type: posting.posting_type,
      source_posting_id: posting.source_posting_id,
      liability_date: posting.liability_date,
      posted_at: posting.posted_at,
      posted_by_id: posting.posted_by_id,
      posted_by_name: posting.posted_by&.name,
      reason: posting.reason,
      idempotency_key: posting.idempotency_key,
      metadata: posting.metadata,
      net_amount: posting.entries.sum { |entry| entry.amount.to_d }.round(2).to_f,
      entries: posting.entries.sort_by { |entry| [ entry.category, entry.component_key, entry.id ] }.map do |entry|
        {
          id: entry.id,
          payroll_item_id: entry.payroll_item_id,
          employee_id: entry.payroll_item&.employee_id,
          component_key: entry.component_key,
          category: entry.category,
          authority: entry.authority,
          amount: entry.amount.to_f,
          pay_component_tax_rule_id: entry.pay_component_tax_rule_id,
          metadata: entry.metadata
        }
      end
    }
  end

  def unclassified_components
    pay_period.payroll_items.flat_map do |item|
      unclassified_custom_deductions(item) + unclassified_adjustments(item)
    end
  end

  def unclassified_custom_deductions(item)
    Array(item.custom_deductions).filter_map do |deduction|
      amount = deduction["amount"].to_d
      next if amount.zero?

      {
        payroll_item_id: item.id,
        employee_id: item.employee_id,
        source: "custom_deduction",
        label: deduction["label"].presence || "Custom deduction",
        amount: amount.to_f,
        reason: "No liability category or payee is stored on legacy custom deductions"
      }
    end
  end

  def unclassified_adjustments(item)
    Array(item.payroll_adjustments).filter_map do |adjustment|
      next unless adjustment["active"] != false
      next unless adjustment["treatment"].in?(%w[pre_tax_deduction post_tax_deduction])

      amount = adjustment["amount"].to_d
      next if amount.zero?

      {
        payroll_item_id: item.id,
        employee_id: item.employee_id,
        source: "payroll_adjustment",
        label: adjustment["label"].presence || "Payroll adjustment",
        amount: amount.to_f,
        reason: "No liability category or payee is stored on ad-hoc payroll adjustments"
      }
    end
  end
end
