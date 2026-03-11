# frozen_string_literal: true

require "csv"

# W2GuCsvExporter
#
# Converts W2GuAggregator output into a CSV string suitable for download.
# Includes one row per employee plus a TOTALS footer row.
#
# Usage:
#   report_data = W2GuAggregator.new(company, year).generate
#   csv_string  = W2GuCsvExporter.new(report_data).generate
#
class W2GuCsvExporter
  HEADERS = [
    "Employee Name",
    "SSN (Last 4)",
    "Box 1 — Wages, Tips & Other Comp",
    "Box 2 — Federal Income Tax Withheld",
    "Box 3 — Social Security Wages",
    "Box 4 — SS Tax Withheld",
    "Box 5 — Medicare Wages & Tips",
    "Box 6 — Medicare Tax Withheld",
    "Box 7 — Social Security Tips",
    "Reported Tips (Uncapped)",
    "Box 7 Capped by Wage Base?"
  ].freeze

  attr_reader :report

  def initialize(report_data)
    @report = report_data
  end

  def generate
    CSV.generate(headers: true, force_quotes: false) do |csv|
      csv << HEADERS

      report[:employees].each { |emp| csv << employee_row(emp) }

      csv << totals_row
    end
  end

  # Suggested filename for Content-Disposition
  def filename
    company_slug = report.dig(:employer, :name)&.gsub(/[^0-9A-Za-z]/, "_")&.downcase || "company"
    "w2gu_#{company_slug}_#{report.dig(:meta, :year)}.csv"
  end

  private

  def employee_row(emp)
    [
      emp[:employee_name],
      emp[:employee_ssn_last4].present? ? "***-**-#{emp[:employee_ssn_last4]}" : "MISSING",
      format_currency(emp[:box1_wages_tips_other_comp]),
      format_currency(emp[:box2_federal_income_tax_withheld]),
      format_currency(emp[:box3_social_security_wages]),
      format_currency(emp[:box4_social_security_tax_withheld]),
      format_currency(emp[:box5_medicare_wages_tips]),
      format_currency(emp[:box6_medicare_tax_withheld]),
      format_currency(emp[:box7_social_security_tips]),
      format_currency(emp[:reported_tips_total]),
      emp[:box7_limited_by_wage_base] ? "Yes" : "No"
    ]
  end

  def totals_row
    t = report[:totals]
    [
      "TOTALS",
      "",
      format_currency(t[:box1_wages_tips_other_comp]),
      format_currency(t[:box2_federal_income_tax_withheld]),
      format_currency(t[:box3_social_security_wages]),
      format_currency(t[:box4_social_security_tax_withheld]),
      format_currency(t[:box5_medicare_wages_tips]),
      format_currency(t[:box6_medicare_tax_withheld]),
      format_currency(t[:box7_social_security_tips]),
      format_currency(t[:reported_tips_total]),
      ""
    ]
  end

  def format_currency(value)
    format("%.2f", value.to_f)
  end
end
