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
    2025 => 176_100.00,
    2026 => 184_500.00
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
        # W-2GU count reflects only employees with committed payroll in year.
        employee_count: rows.length,
        caveats: [
          "This report is a preparation summary and should be reviewed before filing.",
          "Employees missing SSN are flagged in compliance_issues.",
          "Box labels map to W-2GU concepts but final filing format/export is separate.",
          "Box 5 is derived from gross wages + reported tips (pre-tax exclusions not modeled yet).",
          "Box 1 and Box 5 can match in this initial pass when no pre-tax exclusions are modeled."
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
        box7_social_security_tips: rows.sum { |r| r[:box7_social_security_tips].to_f }.round(2),
        reported_tips_total: rows.sum { |r| r[:reported_tips_total].to_f }.round(2)
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
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company.id, pay_date: year_range)
          .select(:id)
      })
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

    if reported_tips > gross_pay
      Rails.logger.warn(
        "[W2GuAggregator] employee=#{employee.id} reported_tips=#{reported_tips} exceed gross_pay=#{gross_pay}; " \
        "clamping wages_only to zero for SS wage-base allocation"
      )
    end
    wages_only = [ gross_pay - reported_tips, 0.0 ].max

    # Approximation for box 1 until pre-tax exclusions are fully modeled.
    # `gross_pay` already includes reported tips in the payroll calculators.
    box1 = gross_pay.round(2)

    # W-2 convention: allocate SS wage base to Box 3 (wages) first,
    # then Box 7 (tips) gets any remaining SS wage-base room.
    box3 = [ wages_only, ss_wage_base ].min.round(2)
    remaining_ss_base = [ ss_wage_base - box3, 0.0 ].max
    box7 = [ reported_tips, remaining_ss_base ].min.round(2)

    # Box 5 should be wage-based, not back-calculated from medicare tax,
    # because Additional Medicare Tax (> $200K) distorts the effective rate.
    box5 = gross_pay.round(2)

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
      box7_social_security_tips: box7,
      reported_tips_total: reported_tips.round(2),
      box7_limited_by_wage_base: reported_tips.positive? && box7 < reported_tips,

      has_missing_ssn: !employee.valid_filing_ssn?,
      has_missing_address: missing_employee_address?(employee)
    }
  end

  def compliance_issues(rows)
    issues = []
    issues << "Employer EIN is missing" if company.ein.blank?
    issues << "Employer address is missing" if missing_employer_address?

    missing_ssn = rows.select { |r| r[:has_missing_ssn] }
    issues << "#{missing_ssn.count} employee(s) missing SSN" if missing_ssn.any?

    missing_employee_address = rows.count { |r| r[:has_missing_address] }
    issues << "#{missing_employee_address} employee(s) missing address" if missing_employee_address.positive?

    issues
  end

  def ss_wage_base
    @ss_wage_base ||= SS_WAGE_BASE_BY_YEAR.fetch(year)
  rescue KeyError
    raise ArgumentError, "SS wage base not configured for #{year}"
  end

  def missing_employer_address?
    company.address_line1.blank? || company.city.blank? || company.state.blank? || company.zip.blank?
  end

  def missing_employee_address?(employee)
    employee.address_line1.blank? || employee.city.blank? || employee.state.blank? || employee.zip.blank?
  end
end
