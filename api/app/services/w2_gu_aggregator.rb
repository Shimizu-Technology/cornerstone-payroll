# frozen_string_literal: true

# W2GuAggregator
#
# Produces annual W-2GU summary data from committed payroll for a company.
# This is a filing-prep dataset (JSON-first) for review/export.
class W2GuAggregator
  attr_reader :company, :year

  def initialize(company, year)
    @company = company
    @year = year.to_i
  end

  def generate
    rows = employees.map { |employee| employee_row(employee) }

    {
      meta: {
        report_type: "w2_gu",
        company_id: company.id,
        company_name: company.name,
        year: year,
        generated_at: Time.current.iso8601,
        employee_count: rows.length,
        caveats: [
          "This report is a preparation summary and should be reviewed before filing.",
          "Employees missing SSN are flagged in compliance_issues.",
          "Box labels map to W-2GU concepts but final filing format/export is separate."
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
        box6_medicare_tax_withheld: rows.sum { |r| r[:box6_medicare_tax_withheld].to_f }.round(2)
      },
      compliance_issues: compliance_issues(rows),
      employees: rows
    }
  end

  private

  def employees
    @employees ||= Employee.where(company_id: company.id).order(:last_name, :first_name)
  end

  def employee_items(employee)
    PayrollItem.joins(:pay_period)
               .where(employee_id: employee.id)
               .where(pay_periods: {
                 status: "committed",
                 pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)
               })
  end

  def employee_row(employee)
    items = employee_items(employee)

    gross_pay = items.sum(:gross_pay).to_f
    reported_tips = items.sum(:reported_tips).to_f
    withholding_tax = items.sum(:withholding_tax).to_f
    ss_tax = items.sum(:social_security_tax).to_f
    medicare_tax = items.sum(:medicare_tax).to_f

    # Approximation for box 1 until pre-tax exclusions are fully modeled.
    box1 = (gross_pay + reported_tips).round(2)

    # Derive wages from withheld tax rates where possible to avoid drift.
    box3 = (ss_tax / 0.062).round(2)
    box5 = (medicare_tax / 0.0145).round(2)

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
    if missing_ssn.any?
      issues << "#{missing_ssn.count} employee(s) missing SSN"
    end

    issues
  end
end
