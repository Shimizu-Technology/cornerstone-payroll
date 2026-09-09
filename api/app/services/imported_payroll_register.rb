# frozen_string_literal: true

class ImportedPayrollRegister
  SOURCE_STATEMENT = "This is the locked QuickBooks payroll exactly as imported. It is available with ordinary payroll reports for review and export, but its paid values cannot be edited or recalculated.".freeze

  def initialize(company_id:, historical_pay_period_id:)
    @company_id = Integer(company_id)
    @historical_pay_period_id = Integer(historical_pay_period_id)
  end

  def call
    period = historical_period
    rows = period.historical_paychecks
                 .includes(employee: :department)
                 .order(Arel.sql("source_employee_name ASC, id ASC"))
                 .map { |paycheck| paycheck_row(paycheck) }
    employees, contractors = rows.partition { |row| row[:employment_type] != "contractor" }

    {
      type: "payroll_register",
      simple_payroll_register_enabled: false,
      meta: {
        company_id: period.company_id,
        company_name: period.company.name,
        generated_at: Time.current.iso8601,
        report_description: "Locked QuickBooks payroll register retained from the source system."
      },
      source: {
        system: "quickbooks_online",
        label: "QuickBooks import",
        locked: true,
        statement: SOURCE_STATEMENT,
        import_batch_id: period.historical_import_batch_id,
        locked_at: period.historical_import_batch.locked_at,
        locked_by_name: period.historical_import_batch.locked_by&.name
      },
      pay_period: {
        key: "imported:#{period.id}",
        id: period.id,
        record_type: "imported",
        start_date: period.start_date,
        end_date: period.end_date,
        pay_date: period.pay_date,
        status: "locked"
      },
      lifecycle: {
        committed: {
          timestamp: period.historical_import_batch.locked_at,
          actor_name: period.historical_import_batch.locked_by&.name
        }
      },
      summary: summary(rows, employees, contractors),
      payroll_adjustments: { totals: [], entries: [], treatment_totals: {} },
      employees: employees,
      contractors: contractors
    }
  end

  private

  attr_reader :company_id, :historical_pay_period_id

  def historical_period
    @historical_period ||= HistoricalPayPeriod
      .joins(:historical_import_batch)
      .includes(:company, historical_import_batch: :locked_by)
      .where(company_id: company_id, period_type: "regular")
      .where(historical_import_batches: { company_id: company_id, status: "locked" })
      .find(historical_pay_period_id)
  end

  def paycheck_row(paycheck)
    employee = paycheck.employee
    first_name, last_name = source_name_parts(paycheck.source_employee_name)
    first_name = employee.first_name if employee
    last_name = employee.last_name if employee
    pretax_lines = deduction_lines(paycheck.pretax_deduction_breakdown, "Pre-tax", "pre_tax")
    employee_tax_lines = deduction_lines(paycheck.employee_tax_breakdown, "Employee tax", "tax")
    after_tax_lines = deduction_lines(paycheck.after_tax_deduction_breakdown, "After-tax", "post_tax")

    {
      employee_id: employee&.id || -paycheck.id,
      historical_paycheck_id: paycheck.id,
      employee_first_name: first_name,
      employee_last_name: last_name,
      employee_name: employee&.full_name || paycheck.source_employee_name,
      department_name: employee&.department&.name,
      employment_type: employee&.employment_type || "employee",
      worker_classification: employee&.employment_type&.humanize || "Imported worker",
      pay_rate: nil,
      scheduled_hours: nil,
      hours_worked: money(paycheck.hours_total),
      overtime_hours: component_amount(paycheck.hours_breakdown, /overtime|\bot\b/i),
      holiday_hours: component_amount(paycheck.hours_breakdown, /holiday/i),
      pto_hours: component_amount(paycheck.hours_breakdown, /pto|paid time/i),
      reported_tips: component_amount(paycheck.earnings_breakdown, /tip/i),
      tips_paid_out: 0.0,
      bonus: component_amount(paycheck.earnings_breakdown, /bonus/i),
      non_taxable_pay: 0.0,
      total_additions: money(paycheck.gross_pay),
      custom_earnings: [],
      custom_earnings_total: 0.0,
      custom_deductions: [],
      custom_deductions_total: 0.0,
      payroll_adjustments: [],
      payroll_adjustment_totals: {},
      payroll_field_entries: [],
      payroll_field_totals: {},
      gross_pay: money(paycheck.gross_pay),
      withholding_tax: money(paycheck.federal_income_tax),
      additional_withholding: 0.0,
      social_security_tax: money(paycheck.social_security_tax),
      medicare_tax: money(paycheck.medicare_tax),
      employer_social_security_tax: component_amount(paycheck.employer_tax_breakdown, /social security/i),
      employer_medicare_tax: component_amount(paycheck.employer_tax_breakdown, /medicare/i),
      retirement_payment: component_amount(paycheck.pretax_deduction_breakdown, /401|retirement/i),
      roth_retirement_payment: component_amount(paycheck.after_tax_deduction_breakdown, /roth/i),
      total_retirement_payment: component_amount(paycheck.pretax_deduction_breakdown, /401|retirement/i) +
        component_amount(paycheck.after_tax_deduction_breakdown, /roth/i),
      employer_retirement_match: component_amount(paycheck.employer_contribution_breakdown, /401|retirement|match/i),
      employer_roth_retirement_match: component_amount(paycheck.employer_contribution_breakdown, /roth/i),
      loan_deduction: component_amount(paycheck.after_tax_deduction_breakdown, /loan/i),
      loan_payment: component_amount(paycheck.after_tax_deduction_breakdown, /loan/i),
      insurance_payment: component_amount(paycheck.after_tax_deduction_breakdown, /insurance|medical|dental|vision/i),
      total_deductions: money(paycheck.pretax_deductions + paycheck.employee_taxes + paycheck.after_tax_deductions),
      net_pay: money(paycheck.net_pay),
      check_number: paycheck.check_number,
      check_date: paycheck.pay_date,
      tip_components: [],
      earnings_breakdown: earning_lines(paycheck.earnings_breakdown),
      deductions_breakdown: pretax_lines + employee_tax_lines + after_tax_lines,
      employer_contributions_breakdown: contribution_lines(paycheck.employer_contribution_breakdown)
    }
  end

  def summary(rows, employees, contractors)
    {
      employee_count: employees.length,
      contractor_count: contractors.length,
      total_gross: sum(employees, :gross_pay),
      total_reported_tips: sum(employees, :reported_tips),
      total_tips_paid_out: sum(employees, :tips_paid_out),
      total_bonus: sum(employees, :bonus),
      total_custom_earnings: 0.0,
      total_withholding: sum(employees, :withholding_tax),
      total_additional_withholding: 0.0,
      total_social_security: sum(employees, :social_security_tax),
      total_medicare: sum(employees, :medicare_tax),
      total_retirement: sum(employees, :total_retirement_payment),
      total_loan_payments: sum(employees, :loan_payment),
      total_custom_deductions: 0.0,
      total_deductions: sum(employees, :total_deductions),
      total_net: sum(employees, :net_pay),
      contractor_total_gross: sum(contractors, :gross_pay),
      contractor_total_net: sum(contractors, :net_pay),
      imported_record_count: rows.length
    }
  end

  def earning_lines(lines)
    normalized_lines(lines).map do |line|
      {
        category: "Imported earning",
        label: line[:label],
        hours: line[:hours],
        rate: line[:rate],
        amount: line[:amount]
      }
    end
  end

  def deduction_lines(lines, category, deduction_type)
    normalized_lines(lines).map do |line|
      { category: category, label: line[:label], deduction_type: deduction_type, amount: line[:amount] }
    end
  end

  def contribution_lines(lines)
    normalized_lines(lines).map do |line|
      { category: "Employer contribution", label: line[:label], amount: line[:amount] }
    end
  end

  def component_amount(lines, pattern)
    normalized_lines(lines).sum { |line| line[:label].match?(pattern) ? line[:amount] : 0.0 }
  end

  def normalized_lines(lines)
    Array(lines).map do |raw|
      line = raw.with_indifferent_access
      {
        label: line[:label].to_s.presence || "Imported component",
        amount: money(line[:amount]),
        hours: line[:hours].present? ? money(line[:hours]) : nil,
        rate: line[:rate].present? ? money(line[:rate]) : nil
      }
    end
  end

  def source_name_parts(value)
    name = value.to_s.strip
    return name.split(",", 2).reverse.map(&:strip) if name.include?(",")

    parts = name.split
    [ parts.first, parts.drop(1).join(" ") ]
  end

  def sum(rows, key)
    rows.sum(0.to_d) { |row| row.fetch(key, 0).to_d }.round(2).to_f
  end

  def money(value)
    value.to_d.round(2).to_f
  end
end
