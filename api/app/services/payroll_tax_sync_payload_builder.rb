# frozen_string_literal: true

class PayrollTaxSyncPayloadBuilder
  attr_reader :pay_period

  def initialize(pay_period)
    @pay_period = pay_period
  end

  def build
    {
      idempotency_key: pay_period.tax_sync_idempotency_key,
      source: "cornerstone-payroll",
      version: "1.0",
      submitted_at: Time.current.iso8601,
      pay_period: pay_period_payload,
      company: company_payload,
      line_items: line_items_payload,
      totals: totals_payload
    }
  end

  private

  def pay_period_payload
    {
      id: pay_period.id,
      start_date: pay_period.start_date.iso8601,
      end_date: pay_period.end_date.iso8601,
      pay_date: pay_period.pay_date.iso8601,
      committed_at: pay_period.committed_at&.iso8601
    }
  end

  def company_payload
    company = pay_period.company
    {
      id: company.id,
      name: company.name,
      ein: company.ein
    }
  end

  def line_items_payload
    pay_period.payroll_items.includes(:employee).map do |item|
      {
        payroll_item_id: item.id,
        employee_id: item.employee_id,
        employee_name: item.employee_full_name,
        employment_type: item.employment_type,
        gross_pay: item.gross_pay.to_f,
        net_pay: item.net_pay.to_f,
        withholding_tax: item.withholding_tax.to_f,
        social_security_tax: item.social_security_tax.to_f,
        medicare_tax: item.medicare_tax.to_f,
        additional_withholding: item.additional_withholding.to_f,
        employer_social_security_tax: item.employer_social_security_tax.to_f,
        employer_medicare_tax: item.employer_medicare_tax.to_f,
        retirement_payment: item.retirement_payment.to_f,
        roth_retirement_payment: item.roth_retirement_payment.to_f,
        ytd_gross: item.ytd_gross.to_f,
        ytd_social_security_tax: item.ytd_social_security_tax.to_f,
        ytd_medicare_tax: item.ytd_medicare_tax.to_f,
        ytd_withholding_tax: item.ytd_withholding_tax.to_f
      }
    end
  end

  def totals_payload
    items = pay_period.payroll_items
    {
      employee_count: items.size,
      gross_pay: items.sum(:gross_pay).to_f,
      net_pay: items.sum(:net_pay).to_f,
      withholding_tax: items.sum(:withholding_tax).to_f,
      social_security_tax: items.sum(:social_security_tax).to_f,
      medicare_tax: items.sum(:medicare_tax).to_f,
      employer_social_security_tax: items.sum(:employer_social_security_tax).to_f,
      employer_medicare_tax: items.sum(:employer_medicare_tax).to_f,
      total_tax_liability: (
        items.sum(:withholding_tax) +
        items.sum(:social_security_tax) +
        items.sum(:medicare_tax) +
        items.sum(:employer_social_security_tax) +
        items.sum(:employer_medicare_tax)
      ).to_f
    }
  end
end
