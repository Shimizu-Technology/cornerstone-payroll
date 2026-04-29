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
      csv << HEADERS

      (report.dig(:employees) || []).each { |emp| csv << employee_row(emp) }

      csv << summary_row
    end
  end

  # Suggested filename for Content-Disposition
  def filename
    pp = report[:pay_period] || {}
    start_d = pp[:start_date].to_s.gsub(/[^0-9\-]/, "")
    end_d   = pp[:end_date].to_s.gsub(/[^0-9\-]/, "")
    if start_d.present? && end_d.present?
      "payroll_register_#{start_d}_to_#{end_d}.csv"
    else
      "payroll_register_unknown_period.csv"
    end
  end

  private

  def employee_row(emp)
    [
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
      format_currency(emp[:total_deductions]),
      format_currency(emp[:net_pay]),
      sanitize_csv_field(emp[:check_number])
    ]
  end

  def summary_row
    s = report[:summary] || {}
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
      format_currency(s[:total_retirement]),
      "",
      format_currency(s[:total_employer_retirement]),
      "",
      "",
      format_currency(s[:total_loan_payments]),
      "",
      format_currency(s[:total_deductions]),
      format_currency(s[:total_net]),
      ""
    ]
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
