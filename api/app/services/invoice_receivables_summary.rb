# frozen_string_literal: true

class InvoiceReceivablesSummary
  def initialize(organization:, billing_profile_id: nil, as_of: Date.current)
    @organization = organization
    @billing_profile_id = billing_profile_id
    @as_of = as_of
  end

  def call
    rows = invoices.includes(:invoice_recipient, :payments, :credit_notes).to_a
    visible_rows = rows.reject(&:archived?)
    open_rows = rows.select do |invoice|
      invoice.balance_due.positive? && !invoice.voided? && !invoice.draft? && !invoice.uncollectible?
    end

    {
      as_of: as_of,
      totals: {
        outstanding: money(open_rows.sum(&:balance_due)),
        overdue: money(open_rows.select { |invoice| overdue?(invoice) }.sum(&:balance_due)),
        paid: money(rows.sum(&:amount_paid)),
        credits: money(rows.sum(&:credit_total)),
        draft_count: visible_rows.count(&:draft?),
        open_count: open_rows.count,
        overdue_count: open_rows.count { |invoice| overdue?(invoice) }
      },
      aging: aging(open_rows),
      by_recipient: by_recipient(open_rows)
    }
  end

  private

  attr_reader :organization, :billing_profile_id, :as_of

  def invoices
    # Archiving controls list visibility only. It must never make an issued,
    # unpaid receivable disappear from financial totals.
    scope = Invoice.where(organization: organization)
    scope = scope.where(invoice_billing_profile_id: billing_profile_id) if billing_profile_id.present?
    scope
  end

  def overdue?(invoice)
    invoice.due_date.present? && invoice.due_date < as_of
  end

  def aging(rows)
    buckets = {
      current: BigDecimal("0"),
      days_1_30: BigDecimal("0"),
      days_31_60: BigDecimal("0"),
      days_61_90: BigDecimal("0"),
      days_91_plus: BigDecimal("0")
    }
    rows.each do |invoice|
      days = invoice.due_date.present? ? (as_of - invoice.due_date).to_i : 0
      key = if days <= 0
        :current
      elsif days <= 30
        :days_1_30
      elsif days <= 60
        :days_31_60
      elsif days <= 90
        :days_61_90
      else
        :days_91_plus
      end
      buckets[key] += invoice.balance_due
    end
    buckets.transform_values { |amount| money(amount) }
  end

  def by_recipient(rows)
    rows.group_by(&:invoice_recipient).map do |recipient, recipient_invoices|
      {
        recipient_id: recipient.id,
        recipient_name: recipient.name,
        invoice_count: recipient_invoices.count,
        outstanding: money(recipient_invoices.sum(&:balance_due)),
        oldest_due_date: recipient_invoices.filter_map(&:due_date).min
      }
    end.sort_by { |row| [ -row[:outstanding], row[:recipient_name] ] }
  end

  def money(value)
    BigDecimal(value.to_s).round(2).to_f
  end
end
