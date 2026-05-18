# frozen_string_literal: true

class QuarterlyCompliancePacketBuilder
  MONTHS_BY_QUARTER = {
    1 => [ 1, 2, 3 ],
    2 => [ 4, 5, 6 ],
    3 => [ 7, 8, 9 ],
    4 => [ 10, 11, 12 ]
  }.freeze

  attr_reader :company, :year, :quarter

  def initialize(company, year, quarter)
    @company = company
    @year = Integer(year)
    @quarter = Integer(quarter)
    raise ArgumentError, "quarter must be 1, 2, 3, or 4" unless MONTHS_BY_QUARTER.key?(@quarter)
  end

  def generate
    {
      meta: meta,
      due_dates: due_dates,
      source_rules: source_rules,
      workflow: workflow_section,
      pay_periods: pay_period_rows,
      form_500: form_500_section,
      w1: w1_section,
      swica: swica_section,
      federal_941: federal_941_section,
      review_checks: review_checks,
      component_taxability: component_taxability
    }
  end

  private

  def quarter_start
    @quarter_start ||= Date.new(year, MONTHS_BY_QUARTER.fetch(quarter).first, 1)
  end

  def quarter_end
    @quarter_end ||= Date.new(year, MONTHS_BY_QUARTER.fetch(quarter).last, -1)
  end

  def due_date
    @due_date ||= (quarter_end >> 1).end_of_month
  end

  def internal_target_date
    @internal_target_date ||= quarter_end + 7.days
  end

  def pay_periods
    @pay_periods ||= PayPeriod.reportable_committed
                              .where(company_id: company.id, pay_date: quarter_start..quarter_end)
                              .order(:pay_date, :id)
  end

  def payroll_items
    @payroll_items ||= PayrollItem.includes(:payroll_item_earnings, :payroll_item_deductions, :employee, :pay_period)
                                  .joins(:employee, :pay_period)
                                  .merge(pay_periods)
                                  .not_voided
                                  .where.not(employment_type: "contractor")
                                  .order("employees.last_name ASC, employees.first_name ASC, pay_periods.pay_date ASC")
                                  .references(:employees, :pay_periods)
                                  .to_a
  end

  def meta
    {
      report_type: "quarterly_compliance_packet",
      company_id: company.id,
      company_name: company.name,
      ein: company.ein,
      company_address_line1: company.address_line1,
      company_address_line2: company.address_line2,
      company_city: company.city,
      company_state: company.state,
      company_zip: company.zip,
      year: year,
      quarter: quarter,
      quarter_label: "Q#{quarter} #{year}",
      quarter_start: quarter_start.iso8601,
      quarter_end: quarter_end.iso8601,
      period_basis: "pay_date",
      generated_at: Time.current.iso8601,
      pay_periods_included: pay_periods.count
    }
  end

  def due_dates
    {
      official_due_date: due_date.iso8601,
      internal_target_date: internal_target_date.iso8601,
      form_500_policy: "per_pay_period",
      notes: [
        "Quarterly filing periods are based on pay date/check date, not pay-period end date.",
        "Cornerstone's operating policy is to prepare quarterly filings in the first week after quarter end.",
        "Cornerstone's operating policy is to deposit Form 500 amounts with each pay period even when the legal schedule may allow less frequent deposits."
      ]
    }
  end

  def source_rules
    {
      guam_track: "Guam withholding belongs to Form 500 and W-1; SWICA reports quarterly employee wage detail.",
      federal_track: "Federal Form 941 reports Social Security, Medicare, Additional Medicare, deposits, and liability schedule.",
      form_941_guam_lines_2_3: "Skipped by default for Guam employers unless employees are subject to U.S. federal income tax withholding.",
      schedule_b: "Schedule B is a liability schedule by pay date, not a payment list."
    }
  end

  def pay_period_rows
    @pay_period_rows ||= pay_periods.map do |period|
      period_items = payroll_items.select { |item| item.pay_period_id == period.id }
      {
        id: period.id,
        start_date: period.start_date.iso8601,
        end_date: period.end_date.iso8601,
        pay_date: period.pay_date.iso8601,
        employee_count: period_items.map(&:employee_id).uniq.count,
        gross_pay: money(period_items.sum(&:gross_pay)),
        net_pay: money(period_items.sum(&:net_pay)),
        deductions: money(deductions_total(period_items)),
        guam_withholding: money(period_items.sum(&:withholding_tax)),
        social_security_tax: money(period_items.sum(&:social_security_tax)),
        medicare_tax: money(period_items.sum(&:medicare_tax)),
        employer_social_security_tax: money(period_items.sum(&:employer_social_security_tax)),
        employer_medicare_tax: money(period_items.sum(&:employer_medicare_tax)),
        federal_941_liability: money(federal_liability_for_items(period_items))
      }
    end
  end

  def workflow_section
    return nil unless persisted_packet

    persisted_packet.workflow_payload
  end

  def persisted_packet
    return @persisted_packet if defined?(@persisted_packet)

    @persisted_packet = QuarterlyCompliancePacket.find_by(company: company, year: year, quarter: quarter)
  end

  def form500_filings_by_pay_period_id
    @form500_filings_by_pay_period_id ||= Form500Filing.where(company_id: company.id, pay_period_id: pay_periods.select(:id)).index_by(&:pay_period_id)
  end

  def form_500_section
    @form_500_section ||= begin
      deposits = pay_period_rows.map do |period|
        filing = form500_filings_by_pay_period_id[period[:id]]
        {
          pay_period_id: period[:id],
          pay_date: period[:pay_date],
          quarter_ending: quarter_end.iso8601,
          amount: filing&.payment_amount.nil? ? nil : money(filing.payment_amount),
          expected_amount: period[:guam_withholding],
          status: filing&.status || "needs_payment_confirmation",
          payment_date: filing&.payment_date&.iso8601,
          confirmation_number: filing&.confirmation_number,
          receipt_attached: filing&.receipt_attached || false,
          notes: filing&.notes
        }
      end

      {
        policy: "per_pay_period",
        total_guam_withholding: money(payroll_items.sum(&:withholding_tax)),
        total_confirmed_payments: money(deposits.select { |row| row[:payment_date].present? && !row[:amount].nil? }.sum { |row| row[:amount].to_f }),
        unconfirmed_amount_count: deposits.count { |row| row[:payment_date].present? && row[:amount].nil? },
        unreconciled_balance: money(payroll_items.sum(&:withholding_tax).to_f - deposits.select { |row| row[:payment_date].present? && !row[:amount].nil? }.sum { |row| row[:amount].to_f }),
        deposits: deposits
      }
    end
  end

  def w1_section
    @w1_section ||= begin
      daily = liability_rows_by_pay_date(:withholding_tax)
      {
        filing_channel: "GuamTax.com Quarterly -> W-1",
        quarter_ending_month: quarter_end.month,
        quarter_ending_year: year,
        daily_liabilities: daily,
        monthly_liabilities: monthly_totals(daily, :amount),
        total_guam_withholding: money(daily.sum { |row| row[:amount].to_f }),
        credits_adjustments: nil,
        balance_due_or_overpayment: nil,
        filing_status: "not_started",
        tie_out: tie_out(
          label: "W-1 Guam withholding",
          expected: payroll_items.sum(&:withholding_tax),
          actual: daily.sum { |row| row[:amount].to_f }
        ),
        filing_steps: [
          "Log in to GuamTax.com.",
          "Choose Quarterly, then W-1.",
          "File the W-1 for #{quarter_end.strftime('%B %Y')}.",
          "Enter withholding liability by actual pay date from this worksheet.",
          "Review Form 500 payments retrieved by GuamTax.",
          "Record the filing confirmation and attach proof in Cornerstone Payroll."
        ]
      }
    end
  end

  def swica_section
    @swica_section ||= begin
      employees = employee_rows
      {
        filing_channel: "GuamTax.com Quarterly -> SWICA (SW-2)",
        filing_status: "not_started",
        employees: employees,
        totals: {
          employee_count: employees.length,
          total_wages: money(employees.sum { |row| row[:swica_wages].to_f }),
          total_tax_withheld: money(employees.sum { |row| row[:guam_withholding].to_f })
        },
        upload_export_ready: swica_upload_validation[:ready],
        upload_export_note: swica_upload_validation[:message],
        upload_validation_errors: swica_upload_validation[:errors],
        filing_steps: [
          "Log in to GuamTax.com.",
          "Choose Quarterly, then SWICA (SW-2).",
          "Use File SWICA for manual entry or Upload SWICA once an upload file is generated.",
          "Confirm employee count, total wages, and total tax withheld against this worksheet.",
          "Record the filing confirmation and attach proof in Cornerstone Payroll."
        ],
        tie_out: tie_out(
          label: "SWICA wages and withholding",
          expected: payroll_items.sum(&:gross_pay),
          actual: employees.sum { |row| row[:swica_wages].to_f }
        )
      }
    end
  end

  def federal_941_section
    @federal_941_section ||= begin
      report = Form941GuAggregator.new(company, year, quarter).generate
      schedule = suggested_federal_deposit_schedule
      {
        filing_channel: "IRS Form 941",
        filing_status: "not_started",
        report: report,
        deposit_schedule: {
          suggested_schedule: schedule,
          schedule_b_required: schedule == "semiweekly",
          firm_payment_policy: "pay_each_pay_period",
          note: "Firm payment policy can be earlier than the IRS deposit schedule. Schedule B is based on liability dates, not payment dates."
        },
        filing_steps: [
          "Prepare IRS Form 941 for #{report.dig(:meta, :quarter_label)}.",
          "For Guam employers, leave lines 2 and 3 blank unless employees are subject to U.S. federal income tax withholding.",
          "Enter Social Security wages, Social Security tips, Medicare wages/tips, and Additional Medicare from this worksheet.",
          "Complete Part 2 using monthly liability or Schedule B as required.",
          "Record filing/payment confirmations and attach proof in Cornerstone Payroll."
        ]
      }
    end
  end

  def employee_rows
    payroll_items.group_by(&:employee).filter_map do |employee, items|
      gross = items.sum(&:gross_pay)
      next if gross.to_f.zero? && items.sum(&:withholding_tax).to_f.zero?

      {
        employee_id: employee.id,
        name: employee.full_name,
        ssn_last_four: employee.ssn_last_four,
        status: employee.status,
        termination_date: employee.termination_date&.iso8601,
        gross_pay: money(gross),
        net_pay: money(items.sum(&:net_pay)),
        deductions: money(deductions_total(items)),
        swica_wages: money(gross),
        reported_tips: money(items.sum(&:reported_tips)),
        non_taxable_pay: money(items.sum(&:non_taxable_pay)),
        guam_withholding: money(items.sum(&:withholding_tax)),
        social_security_tax: money(items.sum(&:social_security_tax)),
        employer_social_security_tax: money(items.sum(&:employer_social_security_tax)),
        medicare_tax: money(items.sum(&:medicare_tax)),
        employer_medicare_tax: money(items.sum(&:employer_medicare_tax)),
        federal_941_liability: money(federal_liability_for_items(items)),
        social_security_wages: money(items.sum { |item| [ item.gross_pay.to_f - item.reported_tips.to_f, 0 ].max }),
        social_security_tips: money(items.sum(&:reported_tips)),
        medicare_wages_tips: money(gross),
        pay_dates: items.map { |item| item.pay_period.pay_date.iso8601 }.uniq
      }
    end
  end

  def component_taxability
    @component_taxability ||= begin
      earnings = payroll_items.flat_map(&:payroll_item_earnings)
      grouped = earnings.group_by { |earning| [ earning.category, earning.label ] }
      grouped.map do |(category, label), rows|
        amount = rows.sum(&:amount)
        {
          category: category,
          label: label,
          amount: money(amount),
          guam_withholding_wages: taxable_earning_category?(category),
          swica_wages: taxable_earning_category?(category),
          social_security_wages: ss_wage_category?(category),
          social_security_tips: category == "tips",
          medicare_wages_tips: taxable_earning_category?(category),
          non_taxable: non_taxable_category?(category)
        }
      end.sort_by { |row| [ row[:category], row[:label] ] }
    end
  end

  def review_checks
    checks = []
    checks << review_check(
      "pay_date_basis",
      true,
      "Packet uses committed payroll selected by pay date/check date.",
      details: {
        basis: "pay_date",
        quarter_start: quarter_start.iso8601,
        quarter_end: quarter_end.iso8601,
        pay_periods_included: pay_periods.count
      },
      href: "/pay-periods"
    )
    checks << review_check(
      "w1_ties_to_payroll",
      w1_section[:tie_out][:status] == "ok",
      "W-1 withholding ties to quarterly Guam withholding.",
      details: w1_section[:tie_out].slice(:expected, :actual, :difference),
      href: "/pay-periods"
    )
    checks << review_check(
      "swica_excludes_zero_pay",
      true,
      "SWICA detail excludes employees with no quarter wages/withholding.",
      details: {
        employee_count: swica_section.dig(:totals, :employee_count),
        total_wages: swica_section.dig(:totals, :total_wages),
        total_tax_withheld: swica_section.dig(:totals, :total_tax_withheld)
      },
      href: "/employees"
    )
    checks << review_check(
      "form_500_payments_reconciled",
      form_500_section[:unreconciled_balance].to_f.zero? && form_500_section[:unconfirmed_amount_count].to_i.zero?,
      "Form 500 payment confirmations reconcile to quarterly Guam withholding.",
      details: {
        expected_withholding: form_500_section[:total_guam_withholding],
        confirmed_payments: form_500_section[:total_confirmed_payments],
        unconfirmed_amount_count: form_500_section[:unconfirmed_amount_count],
        unreconciled_balance: form_500_section[:unreconciled_balance]
      },
      href: "/pay-periods"
    )
    checks << review_check(
      "swica_upload_ready",
      swica_upload_validation[:ready],
      "SWICA upload export has the required employee identifiers and filing fields.",
      details: { errors: swica_upload_validation[:errors].first(5).join("; ").presence || "none" },
      href: "/employees"
    )
    checks << review_check(
      "component_taxability_present",
      component_taxability.any?,
      "Pay component taxability map is present for payroll items with earnings detail.",
      details: { mapped_components: component_taxability.length },
      href: "/pay-periods"
    )
    checks << review_check(
      "form_941_lines_2_3_skipped",
      federal_941_section.dig(:report, :lines, :line2_wages_tips_other).nil? && federal_941_section.dig(:report, :lines, :line3_fit_withheld).nil?,
      "Form 941 lines 2 and 3 are skipped by default for Guam employers.",
      details: {
        line2: federal_941_section.dig(:report, :lines, :line2_wages_tips_other),
        line3: federal_941_section.dig(:report, :lines, :line3_fit_withheld),
        line5e: federal_941_section.dig(:report, :lines, :line5e_total_ss_medicare),
        line12: federal_941_section.dig(:report, :lines, :line12_total_after_credits)
      }
    )
    checks
  end

  def review_check(key, ok, message, details: {}, href: nil)
    { key: key, status: ok ? "ok" : "needs_review", message: message, details: details, href: href }
  end

  def liability_rows_by_pay_date(column)
    payroll_items.group_by { |item| item.pay_period.pay_date }.map do |pay_date, items|
      {
        pay_date: pay_date.iso8601,
        month: pay_date.month,
        amount: money(items.sum(&column))
      }
    end.sort_by { |row| row[:pay_date] }
  end

  def swica_upload_validation
    @swica_upload_validation ||= begin
      errors = []
      employees_map = Employee.where(company_id: company.id, id: employee_rows.map { |row| row[:employee_id] }).index_by(&:id)

      employee_rows.each do |row|
        employee = employees_map[row[:employee_id]]
        errors << "#{row[:name]} is missing a valid 9-digit SSN" unless employee&.valid_filing_ssn?
        errors << "#{row[:name]} is missing address line 1" if employee&.address_line1.blank?
        errors << "#{row[:name]} is missing city" if employee&.city.blank?
        errors << "#{row[:name]} is missing ZIP" if employee&.zip.blank?
      end

      duplicate_ssns = employees_map.values.map(&:ssn_digits).compact.tally.select { |_ssn, count| count > 1 }.keys
      errors << "Duplicate SSNs detected for this quarter" if duplicate_ssns.any?
      {
        ready: errors.empty?,
        errors: errors,
        message: errors.empty? ? "SWICA ASCII wage upload can be generated for GuamTax review." : "Fix employee SSN/address issues before generating the SWICA upload file."
      }
    end
  end

  def monthly_totals(rows, key)
    MONTHS_BY_QUARTER.fetch(quarter).map do |month|
      amount = rows.select { |row| row[:month] == month }.sum { |row| row[key].to_f }
      {
        month: Date::MONTHNAMES[month],
        month_number: month,
        amount: money(amount)
      }
    end
  end

  def federal_liability_for_items(items)
    base_liability = items.sum(&:social_security_tax).to_f +
      items.sum(&:employer_social_security_tax).to_f +
      items.sum(&:medicare_tax).to_f +
      items.sum(&:employer_medicare_tax).to_f

    (base_liability + additional_medicare_tax_for_items(items)).round(2)
  end

  def additional_medicare_tax_for_items(items)
    items.sum { |item| additional_medicare_tax_by_item_id[item.id].to_f }
  end

  def additional_medicare_tax_by_item_id
    @additional_medicare_tax_by_item_id ||= additional_medicare_tax_allocations(payroll_items)
  end

  def additional_medicare_tax_allocations(items)
    Array(items).group_by { |item| [ item.employee_id, item.pay_period.pay_date.year ] }.each_with_object(Hash.new(0.0)) do |((employee_id, _tax_year), employee_items), allocations|
      running_wages = prior_medicare_wages_by_employee_before(employee_items.map { |item| item.pay_period.pay_date }.min)[employee_id].to_f

      employee_items.sort_by { |item| [ item.pay_period.pay_date, item.id ] }.each do |item|
        previous_excess = [ running_wages - Form941GuAggregator::ADD_MEDICARE_THRESHOLD, 0.0 ].max
        running_wages += item.gross_pay.to_f
        current_excess = [ running_wages - Form941GuAggregator::ADD_MEDICARE_THRESHOLD, 0.0 ].max
        taxable_excess = (current_excess - previous_excess).round(2)
        next unless taxable_excess.positive?

        allocations[item.id] = (taxable_excess * Form941GuAggregator::ADD_MEDICARE_RATE).round(2)
      end
    end
  end

  def prior_medicare_wages_by_employee_before(date)
    @prior_medicare_wages_by_employee_before ||= {}
    @prior_medicare_wages_by_employee_before[date] ||= begin
      tax_year_start = Date.new(date.year, 1, 1)

      PayrollItem.joins(:pay_period)
                 .where(company_id: company.id)
                 .not_voided
                 .where.not(employment_type: "contractor")
                 .where(pay_periods: {
                   id: PayPeriod.reportable_committed
                     .where(company_id: company.id, pay_date: tax_year_start...date)
                     .select(:id)
                 })
                 .group(:employee_id)
                 .sum(:gross_pay)
                 .transform_values(&:to_f)
    end
  end

  def prior_medicare_wages_by_employee
    prior_medicare_wages_by_employee_before(quarter_start)
  end

  def additional_medicare_tax_for_lookback_items(items)
    additional_medicare_tax_allocations(items).values.sum
  end

  def deductions_total(items)
    items.sum do |item|
      gross = item.gross_pay.to_f
      taxes = item.withholding_tax.to_f + item.social_security_tax.to_f + item.medicare_tax.to_f
      [ gross - item.net_pay.to_f - taxes, 0 ].max
    end
  end

  def suggested_federal_deposit_schedule
    lookback_start = Date.new(year - 2, 7, 1)
    lookback_end = Date.new(year - 1, 6, 30)
    lookback_periods = PayPeriod.reportable_committed
                                .where(company_id: company.id, pay_date: lookback_start..lookback_end)
    lookback_items = PayrollItem.includes(:pay_period)
                                .joins(:pay_period)
                                .where(pay_periods: { id: lookback_periods.select(:id) })
                                .not_voided
                                .where.not(employment_type: "contractor")
                                .to_a
    liability = lookback_items.sum(&:social_security_tax).to_f +
      lookback_items.sum(&:employer_social_security_tax).to_f +
      lookback_items.sum(&:medicare_tax).to_f +
      lookback_items.sum(&:employer_medicare_tax).to_f +
      additional_medicare_tax_for_lookback_items(lookback_items)
    liability > 50_000 ? "semiweekly" : "monthly"
  end

  def tie_out(label:, expected:, actual:)
    diff = money(actual.to_f - expected.to_f)
    {
      label: label,
      expected: money(expected),
      actual: money(actual),
      difference: diff,
      status: diff.to_f.zero? ? "ok" : "needs_review"
    }
  end

  def taxable_earning_category?(category)
    !non_taxable_category?(category)
  end

  def ss_wage_category?(category)
    taxable_earning_category?(category) && category != "tips"
  end

  def non_taxable_category?(category)
    %w[non_taxable reimbursement].include?(category)
  end

  def money(value)
    BigDecimal(value.to_s).round(2).to_f
  end
end
