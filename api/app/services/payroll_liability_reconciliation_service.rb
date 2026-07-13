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

    {
      status: reconciliation_status(postings),
      pay_period_id: pay_period.id,
      company_id: pay_period.company_id,
      liability_date: pay_period.pay_date,
      net_liability: entries.sum { |entry| entry.amount.to_d }.round(2).to_f,
      totals_by_category: grouped_totals(entries, &:category),
      totals_by_authority: grouped_totals(entries, &:authority),
      postings: postings.map { |posting| posting_json(posting) },
      unclassified_components: unclassified_components,
      payment_tracking_status: "not_in_this_phase",
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
