# frozen_string_literal: true

# CPR-74
# W-2GU filing preflight validator.
# Returns machine-readable findings grouped by blocking/warning severity.
class W2GuPreflightValidator
  Finding = Struct.new(:severity, :code, :message, :employee_id, keyword_init: true)

  attr_reader :company, :year

  def initialize(company:, year:)
    @company = company
    @year = year.to_i
  end

  def run
    findings = []

    findings.concat(employer_findings)
    findings.concat(employee_findings)

    {
      year: year,
      company_id: company.id,
      company_name: company.name,
      run_at: Time.current.iso8601,
      blocking_count: findings.count { |f| f.severity == 'blocking' },
      warning_count: findings.count { |f| f.severity == 'warning' },
      findings: findings.map { |f| serialize(f) }
    }
  end

  private

  def employer_findings
    out = []

    out << Finding.new(
      severity: 'blocking',
      code: 'EMPLOYER_EIN_MISSING',
      message: 'Employer EIN is missing.'
    ) if company.ein.blank?

    if company.address_line1.blank? || company.city.blank? || company.state.blank? || company.zip.blank?
      out << Finding.new(
        severity: 'blocking',
        code: 'EMPLOYER_ADDRESS_INCOMPLETE',
        message: 'Employer address is incomplete (address/city/state/zip required).'
      )
    end

    out
  end

  def employee_findings
    out = []

    employee_ids = PayrollItem
      .joins(:pay_period)
      .where(pay_periods: { company_id: company.id, status: 'committed' })
      .where('EXTRACT(YEAR FROM pay_periods.pay_date) = ?', year)
      .distinct
      .pluck(:employee_id)

    Employee.where(id: employee_ids).find_each do |employee|
      if employee.ssn_last_four.blank?
        out << Finding.new(
          severity: 'blocking',
          code: 'EMPLOYEE_SSN_MISSING',
          message: "Employee #{employee.full_name} is missing SSN.",
          employee_id: employee.id
        )
      end

      if employee.address_line1.blank? || employee.city.blank? || employee.state.blank? || employee.zip.blank?
        out << Finding.new(
          severity: 'blocking',
          code: 'EMPLOYEE_ADDRESS_INCOMPLETE',
          message: "Employee #{employee.full_name} has incomplete address.",
          employee_id: employee.id
        )
      end
    end

    out
  end

  def serialize(finding)
    {
      severity: finding.severity,
      code: finding.code,
      message: finding.message,
      employee_id: finding.employee_id
    }
  end
end
