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
      csv << [ "Year",              period[:year].to_s ]
      csv << [ "Quarter",           period[:quarter] ? "Q#{period[:quarter]}" : "Full Year" ]
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
    end
  end

  # Suggested filename for Content-Disposition
  def filename
    period  = report[:period] || {}
    year    = period[:year] || "unknown"
    quarter = period[:quarter] ? "_q#{period[:quarter]}" : ""
    "tax_summary_#{year}#{quarter}.csv"
  end

  private

  def format_currency(value)
    format("%.2f", value.to_f)
  end
end
