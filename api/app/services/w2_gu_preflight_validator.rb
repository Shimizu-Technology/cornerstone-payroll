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
    employee_ids, source_findings = filing_employee_ids
    findings.concat(source_findings)
    findings.concat(employee_findings(employee_ids))

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

  def employee_findings(employee_ids)
    out = []

    if employee_ids.empty?
      out << Finding.new(
        severity: 'blocking',
        code: 'NO_COMMITTED_PAYROLL',
        message: "No committed Cornerstone or locked imported payroll found for #{year}. Cannot validate W-2 readiness."
      )
      return out
    end

    Employee.where(id: employee_ids).find_each do |employee|
      unless employee.valid_filing_ssn?
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

  def filing_employee_ids
    native_ids = PayrollItem
      .joins(:pay_period)
      .where(company_id: company.id)
      .not_voided
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
          .where(company_id: company.id, pay_date: year_range)
          .select(:id)
      })
      .distinct
      .pluck(:employee_id)

    return [ native_ids, [] ] unless locked_historical_payroll?

    source = HistoricalPayrollFilingSource.new(company)
    source.validate!(range: year_range)
    historical_ids = source.annual_balances(year).filter_map(&:employee_id)
    [ (native_ids + historical_ids).uniq, [] ]
  rescue ArgumentError => e
    finding = Finding.new(
      severity: 'blocking',
      code: 'HISTORICAL_PAYROLL_NOT_READY',
      message: "Locked imported payroll is not ready for W-2GU filing review: #{e.message}"
    )
    [ native_ids || [], [ finding ] ]
  end

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def locked_historical_payroll?
    company.historical_import_batches
      .joins(:historical_paychecks)
      .where(status: "locked", historical_paychecks: { pay_date: year_range })
      .exists?
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
