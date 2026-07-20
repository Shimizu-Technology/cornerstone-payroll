# frozen_string_literal: true

require "csv"

# TaxSummaryCsvExporter
#
# Converts tax_summary report data into a CSV string suitable for download.
# Includes totals, period info, and per-category rows.
#
# Usage:
#   report_data = build_tax_summary_data(year, quarter)
#   exporter    = TaxSummaryCsvExporter.new(report_data)
#   send_data exporter.generate, filename: exporter.filename, type: "text/csv; charset=utf-8", disposition: "attachment"
#
class TaxSummaryCsvExporter
  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    period = report[:period] || {}
    totals = report[:totals] || {}

    CSV.generate(headers: false, force_quotes: false) do |csv|
      # Period metadata header section
      csv << [ "Tax Summary Report" ]
      csv << [ "Client", report.dig(:meta, :company_name).to_s ] if report.dig(:meta, :company_name).present?
      csv << [ "Description", report.dig(:meta, :report_description).to_s ] if report.dig(:meta, :report_description).present?
      csv << [ "Reporting Basis",    "Pay date" ]
      csv << [ "Period",             period_label(period) ]
      csv << [ "Period Start",      period[:start_date].to_s ]
      csv << [ "Period End",        period[:end_date].to_s ]
      csv << [ "Pay Periods Included", report[:pay_periods_included].to_s ]
      csv << [ "Employee Count",    report[:employee_count].to_s ]
      csv << []

      # Totals table
      csv << [ "Category", "Amount" ]
      csv << [ "Gross Wages",                  format_currency(totals[:gross_wages]) ]
      csv << [ "Withholding Tax",              format_currency(totals[:withholding_tax]) ]
      csv << [ "Social Security (Employee)",   format_currency(totals[:social_security_employee]) ]
      csv << [ "Social Security (Employer)",   format_currency(totals[:social_security_employer]) ]
      csv << [ "Medicare (Employee)",          format_currency(totals[:medicare_employee]) ]
      csv << [ "Medicare (Employer)",          format_currency(totals[:medicare_employer]) ]
      csv << [ "Total Employment Taxes",       format_currency(totals[:total_employment_taxes]) ]
      csv << []

      csv << [ "Payroll Field Reconciliation" ]
      csv << [ "Field", "Tax Treatment", "Category", "Paid By", "Employees", "Amount" ]
      Array(report.dig(:payroll_fields, :totals)).each do |entry|
        csv << [
          entry[:label], entry[:tax_treatment].to_s.humanize, entry[:category].to_s.humanize,
          entry[:employer_paid] ? "Employer" : "Employee", entry[:employee_count],
          format_currency(entry[:amount])
        ]
      end
    end
  end

  # Suggested filename for Content-Disposition
  def filename
    period  = report[:period] || {}
    token = if period[:custom]
      "#{period[:start_date]}_to_#{period[:end_date]}"
    else
      [ period[:year] || "unknown", ("q#{period[:quarter]}" if period[:quarter]) ].compact.join("_")
    end
    company_slug = report.dig(:meta, :company_name).to_s.parameterize.presence
    prefix = [ "tax_summary", company_slug ].compact.join("_")
    "#{prefix}_#{token}.csv"
  end

  private

  def format_currency(value)
    format("%.2f", value.to_f)
  end

  def period_label(period)
    return period[:label] if period[:label].present?
    return "Q#{period[:quarter]} #{period[:year]}" if period[:quarter]

    "#{period[:year]} Full Year"
  end
end
