# frozen_string_literal: true

# Issued fee value, grouped by explicitly linked payroll client and service month.
# Multi-month invoices belong wholly to the month containing service_period_start.
# Legacy imports without classified lines contribute zero (unknown fee breakdown).
class InvoiceServiceFeeRevenue
  def self.call(finance_book:)
    invoices = Invoice.where(finance_book: finance_book, status: %w[open uncollectible]).includes(:line_items)
    invoices.group_by do |invoice|
      [ invoice.company_id, (invoice.service_period_start || invoice.invoice_date).beginning_of_month ]
    end.map do |(company_id, service_month), rows|
      { company_id: company_id, service_month: service_month, amount: rows.sum(BigDecimal("0"), &:service_fee_amount) }
    end
  end
end
