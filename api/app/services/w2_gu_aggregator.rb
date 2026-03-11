# frozen_string_literal: true

# W2GuAggregator
#
# Produces annual W-2GU summary data from committed payroll for a company.
# This is a filing-prep dataset (JSON-first) for review/export.
class W2GuAggregator
  SS_WAGE_BASE_BY_YEAR = {
    2020 => 137_700.00,
    2021 => 142_800.00,
    2022 => 147_000.00,
    2023 => 160_200.00,
    2024 => 168_600.00,
    2025 => 176_100.00
  }.freeze

  attr_reader :company, :year

  def initialize(company, year)
    @company = company
    @year = year.to_i
  end

  def generate
    # Fail fast on unsupported years so operators don't file with wrong caps.
    ss_wage_base

    rows = employees.map { |employee| employee_row(employee) }

    {
      meta: {
        report_type: "w2_gu",
        company_id: company.id,
        company_name: company.name,
        year: year,
        generated_at: Time.current.iso8601,
        # W-2GU count should reflect only employees with committed payroll in year.
        employee_count: rows.length,
        caveats: [
          "This report is a preparation summary and should be reviewed before filing.",
          "Employees missing SSN are flagged in compliance_issues.",
          "Box labels map to W-2GU concepts but final filing format/export is separate.",
          "Box 5 is derived from gross wages + reported tips (pre-tax exclusions not modeled yet)."
        ]
      },
      employer: {
        name: company.name,
        ein: company.ein,
        address: company.full_address
      },
      totals: {
        box1_wages_tips_other_comp: rows.sum { |r| r[:box1_wages_tips_other_comp].to_f }.round(2),
        box2_federal_income_tax_withheld: rows.sum { |r| r[:box2_federal_income_tax_withheld].to_f }.round(2),
        box3_social_security_wages: rows.sum { |r| r[:box3_social_security_wages].to_f }.round(2),
        box4_social_security_tax_withheld: rows.sum { |r| r[:box4_social_security_tax_withheld].to_f }.round(2),
        box5_medicare_wages_tips: rows.sum { |r| r[:box5_medicare_wages_tips].to_f }.round(2),
        box6_medicare_tax_withheld: rows.sum { |r| r[:box6_medicare_tax_withheld].to_f }.round(2),
        box7_social_security_tips: rows.sum { |r| r[:box7_social_security_tips].to_f }.round(2)
      },
      compliance_issues: compliance_issues(rows),
      employees: rows
    }
  end

  private

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  # Pre-aggregate payroll sums by employee to avoid N+1 SUM queries.
  def aggregated_items
    @aggregated_items ||= PayrollItem
      .joins(:pay_period)
      .where(pay_periods: { company_id: company.id, status: "committed", pay_date: year_range })
      .group(:employee_id)
      .select(
        :employee_id,
        "SUM(gross_pay) AS gross_pay",
        "SUM(reported_tips) AS reported_tips",
        "SUM(withholding_tax) AS withholding_tax",
        "SUM(social_security_tax) AS ss_tax",
        "SUM(medicare_tax) AS medicare_tax"
      )
      .index_by(&:employee_id)
  end

  def employees
    @employees ||= Employee
      .where(company_id: company.id, id: aggregated_items.keys)
      .order(:last_name, :first_name)
  end

  def employee_row(employee)
    sums = aggregated_items[employee.id]

    gross_pay = sums&.gross_pay.to_f
    reported_tips = sums&.reported_tips.to_f
    withholding_tax = sums&.withholding_tax.to_f
    ss_tax = sums&.ss_tax.to_f
    medicare_tax = sums&.medicare_tax.to_f

    # Approximation for box 1 until pre-tax exclusions are fully modeled.
    box1 = (gross_pay + reported_tips).round(2)

    # Box 3 (Social Security wages) should be wage-based and capped by SS wage base.
    box3 = [ (gross_pay + reported_tips), ss_wage_base ].min.round(2)

    # Box 5 should be wage-based, not back-calculated from medicare tax,
    # because Additional Medicare Tax (> $200K) distorts the effective rate.
    box5 = (gross_pay + reported_tips).round(2)

    {
      employee_id: employee.id,
      employee_name: employee.full_name,
      employee_ssn_last4: employee.ssn_last_four,
      employee_address: employee.full_address,

      box1_wages_tips_other_comp: box1,
      box2_federal_income_tax_withheld: withholding_tax.round(2),
      box3_social_security_wages: box3,
      box4_social_security_tax_withheld: ss_tax.round(2),
      box5_medicare_wages_tips: box5,
      box6_medicare_tax_withheld: medicare_tax.round(2),
      box7_social_security_tips: reported_tips.round(2),

      has_missing_ssn: employee.ssn_last_four.blank?
    }
  end

  def compliance_issues(rows)
    issues = []
    issues << "Employer EIN is missing" if company.ein.blank?

    missing_ssn = rows.select { |r| r[:has_missing_ssn] }
    issues << "#{missing_ssn.count} employee(s) missing SSN" if missing_ssn.any?

    issues
  end

  def ss_wage_base
    SS_WAGE_BASE_BY_YEAR.fetch(year)
  rescue KeyError
    raise ArgumentError, "SS wage base not configured for #{year}"
  end
end
