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
    HEADERS + payroll_field_columns.map { |column| payroll_field_header(column) }
  end

  def payroll_rows
    Array(report.dig(:employees)) + Array(report.dig(:contractors))
  end

  def payroll_field_columns
    @payroll_field_columns ||= payroll_rows.flat_map { |employee| active_payroll_field_entries(employee) }
      .group_by { |entry| payroll_field_key(entry) }
      .map do |key, entries|
        entry = entries.first
        {
          key: key,
          label: entry[:label].to_s,
          tax_treatment: entry[:tax_treatment].to_s,
          group: payroll_field_group(entry)
        }
      end
      .sort_by { |column| [ payroll_field_group_order(column[:group]), column[:tax_treatment], column[:label] ] }
  end

  def payroll_field_amount(emp, column)
    matching = active_payroll_field_entries(emp).select { |entry| payroll_field_key(entry) == column[:key] }
    return nil if matching.empty?

    matching.sum { |entry| entry[:amount].to_f }
  end

  def active_payroll_field_entries(employee)
    Array(employee[:payroll_field_entries]).reject { |entry| entry[:active] == false }
  end

  def payroll_field_key(entry)
    [ entry[:label].to_s, entry[:kind].to_s, entry[:tax_treatment].to_s, entry[:employee_paid] == true, entry[:employer_paid] == true ]
  end

  def payroll_field_group(entry)
    treatment = entry[:tax_treatment].to_s
    return :employer if treatment == "employer_contribution" || (entry[:employer_paid] == true && entry[:employee_paid] != true)
    return :deduction if entry[:kind].to_s == "deduction" || %w[pre_tax_deduction post_tax_deduction].include?(treatment)

    :addition
  end

  def payroll_field_group_order(group)
    { addition: 0, deduction: 1, employer: 2 }.fetch(group, 3)
  end

  def payroll_field_header(column)
    effect = { addition: "in gross", deduction: "in deductions", employer: "employer only" }.fetch(column[:group])
    "Payroll Field - #{column[:label]} (#{column[:tax_treatment].humanize}; #{effect})"
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
    base_row + payroll_field_columns.map do |column|
      amount = payroll_field_amount(emp, column)
      amount.nil? ? "" : format_currency(amount)
    end
  end

  def summary_row
    s = report[:summary] || {}

    [
      sanitize_csv_field(summary_label(s)),
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      format_currency(total_for(:reported_tips)),
      format_currency(total_for(:tips_paid_out)),
      format_currency(total_for(:bonus)),
      format_currency(total_for(:custom_earnings_total)),
      format_currency(total_for(:non_taxable_pay)),
      format_currency(total_for(:gross_pay)),
      format_currency(total_for(:withholding_tax)),
      format_currency(total_for(:additional_withholding)),
      format_currency(total_for(:social_security_tax)),
      format_currency(total_for(:medicare_tax)),
      format_currency(total_for(:employer_social_security_tax)),
      format_currency(total_for(:employer_medicare_tax)),
      format_currency(total_for(:retirement_payment)),
      format_currency(total_for(:roth_retirement_payment)),
      format_currency(total_for(:employer_retirement_match)),
      format_currency(total_for(:employer_roth_retirement_match)),
      "",
      format_currency(total_for(:loan_payment)),
      "",
      format_currency(total_for(:custom_deductions_total)),
      format_currency(total_for(:total_deductions)),
      format_currency(total_for(:net_pay)),
      ""
    ] + payroll_field_columns.map { |column| format_currency(payroll_rows.sum { |emp| payroll_field_amount(emp, column).to_f }) }
  end

  def summary_label(summary)
    employee_count = summary[:employee_count] || Array(report.dig(:employees)).size
    contractor_count = summary[:contractor_count] || Array(report.dig(:contractors)).size
    label = "TOTALS (#{employee_count} employees"
    label += ", #{contractor_count} contractors" if contractor_count.to_i.positive?
    "#{label})"
  end

  def total_for(key)
    payroll_rows.sum { |row| row[key].to_f }
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
