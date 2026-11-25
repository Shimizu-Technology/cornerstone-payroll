# frozen_string_literal: true

# Issued fee value, grouped by explicitly linked payroll client and service month.
# Multi-month invoices belong wholly to the month containing service_period_start.
# Legacy imports without classified lines contribute zero (unknown fee breakdown).
# tax_prep_service_names (optional) adds tax_prep_amount: the part of amount
# from service-fee lines whose product/service name is one of those names
# (case and spacing ignored), with the same proportional discount.
# by_recipient: true splits the invoices with no payroll client by invoice
# customer, adding invoice_recipient_id to those rows (client profitability
# links some Tax clients straight to such a customer).
class InvoiceServiceFeeRevenue
  # live_clients_only drops invoices whose payroll client, or whose customer's
  # payroll client, is not a live client (a stale demo or practice-copy link).
  # Unallocated invoices with no payroll client either way are kept.
  def self.call(finance_book:, service_month_from: nil, service_month_through: nil, tax_prep_service_names: nil, by_recipient: false,
                live_clients_only: false)
    invoices = Invoice.where(finance_book: finance_book, status: %w[open uncollectible]).includes(:line_items)
    if live_clients_only
      non_live = Company.where.not(payroll_environment: "live").select(:id)
      invoices = invoices.where("invoices.company_id IS NULL OR invoices.company_id NOT IN (?)", non_live)
                         .where("invoices.invoice_recipient_id IS NULL OR invoices.invoice_recipient_id NOT IN (?)",
                                InvoiceRecipient.where(company_id: non_live).select(:id))
    end
    if service_month_from
      invoices = invoices.where("COALESCE(service_period_start, invoice_date) >= ?", service_month_from.beginning_of_month)
    end
    if service_month_through
      invoices = invoices.where("COALESCE(service_period_start, invoice_date) <= ?", service_month_through.end_of_month)
    end
    keys = tax_prep_service_names&.map { |name| service_key(name) }&.to_set
    invoices.group_by do |invoice|
      recipient_id = by_recipient && invoice.company_id.nil? ? invoice.invoice_recipient_id : nil
      [ invoice.company_id, recipient_id, (invoice.service_period_start || invoice.invoice_date).beginning_of_month ]
    end.map do |(company_id, recipient_id, service_month), rows|
      row = { company_id: company_id, service_month: service_month, amount: rows.sum(BigDecimal("0"), &:service_fee_amount) }
      row[:invoice_recipient_id] = recipient_id if by_recipient && company_id.nil?
      next row if keys.nil?

      tax_prep = keys.empty? ? BigDecimal("0") : rows.sum(BigDecimal("0")) { |invoice| invoice.service_fee_amount { |line| keys.include?(service_key(line.item_name)) } }
      row.merge(tax_prep_amount: tax_prep)
    end
  end

  def self.service_key(name)
    name.to_s.squish.downcase
  end
end
