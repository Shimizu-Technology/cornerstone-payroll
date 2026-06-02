# frozen_string_literal: true

require "csv"

# PayrollRegisterCsvExporter
#
# Converts payroll_register report data into a CSV string suitable for download.
# Includes one row per employee plus a SUMMARY footer row.
#
# Usage:
#   report_data = build_payroll_register_data(pay_period)
#   exporter    = PayrollRegisterCsvExporter.new(report_data)
#   send_data exporter.generate, filename: exporter.filename, type: "text/csv; charset=utf-8", disposition: "attachment"
#
class PayrollRegisterCsvExporter
  HEADERS = [
    "Last Name",
    "First Name",
    "Employee Name",
    "Department",
    "Employment Type",
    "Pay Rate",
    "Hours Worked",
    "Overtime Hours",
    "Holiday Hours",
    "PTO Hours",
    "Reported Tips",
    "Tips Paid Out",
    "Bonus",
    "Custom Earnings",
    "Non-Taxable Pay",
    "Gross Pay",
    "Withholding Tax",
    "Addtl Withholding",
    "Social Security Tax",
    "Medicare Tax",
    "Employer Social Security",
    "Employer Medicare",
    "401(k)",
    "Roth 401(k)",
    "Employer Match",
    "Employer Roth Match",
    "Loan Deduction",
    "Loan Payment",
    "Insurance",
    "Custom Deductions",
    "Total Deductions",
    "Net Pay",
    "Check Number"
  ].freeze

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    CSV.generate(headers: true, force_quotes: false) do |csv|
      csv << headers

      payroll_rows.each { |emp| csv << employee_row(emp) }

      csv << summary_row
    end
  end

  # Suggested filename for Content-Disposition
  def filename
    pp = report[:pay_period] || {}
    company_slug = report.dig(:meta, :company_name).to_s.parameterize.presence
    start_d = pp[:start_date].to_s.gsub(/[^0-9\-]/, "")
    end_d   = pp[:end_date].to_s.gsub(/[^0-9\-]/, "")
    prefix = [ "payroll_register", company_slug ].compact.join("_")
    if start_d.present? && end_d.present?
      "#{prefix}_#{start_d}_to_#{end_d}.csv"
    else
      "#{prefix}_unknown_period.csv"
    end
  end

  private

  def headers
    HEADERS + payroll_field_columns.map { |column| "Payroll Field - #{column[:label]} (#{column[:tax_treatment].to_s.humanize})" }
  end

  def payroll_rows
    Array(report.dig(:employees)) + Array(report.dig(:contractors))
  end

  def payroll_field_columns
    @payroll_field_columns ||= payroll_rows.flat_map { |emp| Array(emp[:payroll_field_entries]) }
      .group_by { |entry| [ entry[:label], entry[:tax_treatment] ] }
      .keys
      .sort_by { |label, treatment| [ treatment.to_s, label.to_s ] }
      .map { |label, treatment| { label: label, tax_treatment: treatment } }
  end

  def payroll_field_amount(emp, column)
    Array(emp[:payroll_field_entries]).sum do |entry|
      entry[:label].to_s == column[:label].to_s && entry[:tax_treatment].to_s == column[:tax_treatment].to_s ? entry[:amount].to_f : 0.0
    end
  end

  def employee_row(emp)
    base_row = [
      sanitize_csv_field(emp[:employee_last_name]),
      sanitize_csv_field(emp[:employee_first_name]),
      sanitize_csv_field(emp[:employee_name]),
      sanitize_csv_field(emp[:department_name]),
      sanitize_csv_field(emp[:employment_type]),
      format_currency(emp[:pay_rate]),
      emp[:hours_worked].to_f,
      emp[:overtime_hours].to_f,
      emp[:holiday_hours].to_f,
      emp[:pto_hours].to_f,
      format_currency(emp[:reported_tips]),
      format_currency(emp[:tips_paid_out]),
      format_currency(emp[:bonus]),
      format_currency(emp[:custom_earnings_total]),
      format_currency(emp[:non_taxable_pay]),
      format_currency(emp[:gross_pay]),
      format_currency(emp[:withholding_tax]),
      format_currency(emp[:additional_withholding]),
      format_currency(emp[:social_security_tax]),
      format_currency(emp[:medicare_tax]),
      format_currency(emp[:employer_social_security_tax]),
      format_currency(emp[:employer_medicare_tax]),
      format_currency(emp[:retirement_payment]),
      format_currency(emp[:roth_retirement_payment]),
      format_currency(emp[:employer_retirement_match]),
      format_currency(emp[:employer_roth_retirement_match]),
      format_currency(emp[:loan_deduction]),
      format_currency(emp[:loan_payment]),
      format_currency(emp[:insurance_payment]),
      format_currency(emp[:custom_deductions_total]),
      format_currency(emp[:total_deductions]),
      format_currency(emp[:net_pay]),
      sanitize_csv_field(emp[:check_number])
    ]
    base_row + payroll_field_columns.map { |column| format_currency(payroll_field_amount(emp, column)) }
  end

  def summary_row
    s = report[:summary] || {}
    total_traditional_retirement = s.key?(:total_traditional_retirement) ? s[:total_traditional_retirement] : s[:total_retirement]
    total_employer_traditional_retirement = s.key?(:total_employer_traditional_retirement) ? s[:total_employer_traditional_retirement] : s[:total_employer_retirement]

    [
      sanitize_csv_field("TOTALS (#{s[:employee_count]} employees)"),
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      format_currency(s[:total_reported_tips]),
      format_currency(s[:total_tips_paid_out]),
      format_currency(s[:total_bonus]),
      format_currency(s[:total_custom_earnings]),
      format_currency(s[:total_non_taxable_pay]),
      format_currency(s[:total_gross]),
      format_currency(s[:total_withholding]),
      format_currency(s[:total_additional_withholding]),
      format_currency(s[:total_social_security]),
      format_currency(s[:total_medicare]),
      format_currency(s[:total_employer_social_security]),
      format_currency(s[:total_employer_medicare]),
      format_currency(total_traditional_retirement),
      format_currency(s[:total_roth_retirement]),
      format_currency(total_employer_traditional_retirement),
      format_currency(s[:total_employer_roth_retirement]),
      "",
      format_currency(s[:total_loan_payments]),
      "",
      format_currency(s[:total_custom_deductions]),
      format_currency(s[:total_deductions]),
      format_currency(s[:total_net]),
      ""
    ] + payroll_field_columns.map { |column| format_currency(payroll_rows.sum { |emp| payroll_field_amount(emp, column) }) }
  end

  def format_currency(value)
    format("%.2f", value.to_f)
  end

  # Mitigates CSV formula injection when opened in spreadsheet apps.
  def sanitize_csv_field(value)
    str = value.to_s
    str.start_with?("=", "+", "-", "@", "\t", "\r") ? "'#{str}" : str
  end
end
