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
    "Employee Name",
    "Employment Type",
    "Pay Rate",
    "Hours Worked",
    "Overtime Hours",
    "Gross Pay",
    "Withholding Tax",
    "Social Security Tax",
    "Medicare Tax",
    "Retirement",
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
      sanitize_csv_field(emp[:employee_name]),
      sanitize_csv_field(emp[:employment_type]),
      format_currency(emp[:pay_rate]),
      emp[:hours_worked].to_f,
      emp[:overtime_hours].to_f,
      format_currency(emp[:gross_pay]),
      format_currency(emp[:withholding_tax]),
      format_currency(emp[:social_security_tax]),
      format_currency(emp[:medicare_tax]),
      format_currency(emp[:retirement_payment]),
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
      format_currency(s[:total_gross]),
      format_currency(s[:total_withholding]),
      format_currency(s[:total_social_security]),
      format_currency(s[:total_medicare]),
      format_currency(s[:total_retirement]),
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
