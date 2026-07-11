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
          "Box 1 = Gross wages minus pre-tax 401(k) deferrals (Code D). Box 5 = Gross wages (not reduced by 401k).",
          "Box 12 codes: D = 401(k) elective deferrals, AA = Roth 401(k) contributions.",
          "For 2026+, Box 12 code TP reports cash tips and code TT reports qualified overtime compensation; Box 14b reports Treasury tipped occupation codes.",
          "Box 13 Retirement plan checkbox is set if the employee has a retirement contribution rate > 0.",
          "Committed taxable wage bases are used when present. Legacy rows without stored bases use a clearly flagged compatibility fallback.",
          "If payroll items were committed before tips were embedded in gross_pay, Box 1/Box 5 may understate total compensation for those periods. Verify transition-year rows manually."
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
        reported_tips_total: rows.sum { |r| r[:reported_tips_total].to_f }.round(2),
        box12_code_d_total: rows.sum { |r| (r[:box12] || []).select { |e| e[:code] == "D" }.sum { |e| e[:amount] } }.round(2),
        box12_code_aa_total: rows.sum { |r| (r[:box12] || []).select { |e| e[:code] == "AA" }.sum { |e| e[:amount] } }.round(2),
        box12_code_tp_total: rows.sum { |r| (r[:box12] || []).select { |e| e[:code] == "TP" }.sum { |e| e[:amount] } }.round(2),
        box12_code_tt_total: rows.sum { |r| (r[:box12] || []).select { |e| e[:code] == "TT" }.sum { |e| e[:amount] } }.round(2),
        retirement_plan_participants: rows.count { |r| r[:box13_retirement_plan] }
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
      .where(company_id: company.id)
      .not_voided
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
        "SUM(medicare_tax) AS medicare_tax",
        "SUM(COALESCE(retirement_payment, 0)) AS retirement_total",
        "SUM(COALESCE(roth_retirement_payment, 0)) AS roth_retirement_total",
        "SUM(COALESCE(non_taxable_pay, 0)) AS non_taxable_total",
        "SUM(COALESCE(social_security_taxable_wages, GREATEST(gross_pay - reported_tips, 0))) AS ss_wages_base",
        "SUM(COALESCE(social_security_taxable_tips, reported_tips)) AS ss_tips_base",
        "SUM(COALESCE(medicare_taxable_wages, gross_pay)) AS medicare_wages_base",
        "SUM(COALESCE(cash_tips_reported, reported_tips)) AS cash_tips_total",
        "SUM(COALESCE(qualified_overtime_compensation, 0)) AS qualified_overtime_total",
        "COUNT(*) FILTER (WHERE social_security_taxable_wages IS NULL OR social_security_taxable_tips IS NULL OR medicare_taxable_wages IS NULL) AS missing_tax_base_count",
        "COUNT(*) FILTER (WHERE reported_tips <> 0 AND cash_tips_reported IS NULL) AS missing_tip_classification_count",
        "COUNT(*) FILTER (WHERE overtime_hours <> 0 AND qualified_overtime_compensation IS NULL) AS missing_qualified_overtime_count"
      )
      .index_by(&:employee_id)
  end

  def employees
    @employees ||= Employee
      .where(company_id: company.id, id: aggregated_items.keys)
      .where.not(employment_type: "contractor")
      .includes(:employee_tipped_occupations)
      .order(:last_name, :first_name)
  end

  def employee_row(employee)
    sums = aggregated_items[employee.id]

    gross_pay = sums&.gross_pay.to_f
    reported_tips = sums&.reported_tips.to_f
    withholding_tax = sums&.withholding_tax.to_f
    ss_tax = sums&.ss_tax.to_f
    medicare_tax = sums&.medicare_tax.to_f
    retirement_total = sums&.retirement_total.to_f
    roth_retirement_total = sums&.roth_retirement_total.to_f
    non_taxable_total = sums&.non_taxable_total.to_f
    ss_wages_base = sums&.ss_wages_base.to_f
    ss_tips_base = sums&.ss_tips_base.to_f
    medicare_wages_base = sums&.medicare_wages_base.to_f
    cash_tips_total = sums&.cash_tips_total.to_f
    qualified_overtime_total = sums&.qualified_overtime_total.to_f

    if reported_tips > gross_pay
      Rails.logger.warn(
        "[W2GuAggregator] employee=#{employee.id} reported_tips=#{reported_tips} exceed gross_pay=#{gross_pay}; " \
        "clamping wages_only to zero for SS wage-base allocation"
      )
    end
    # Box 1: Wages minus pre-tax retirement (401k) contributions
    box1 = (gross_pay - retirement_total).round(2)

    # W-2 convention: allocate SS wage base to Box 3 (wages) first,
    # then Box 7 (tips) gets any remaining SS wage-base room.
    box3 = [ ss_wages_base, ss_wage_base ].min.round(2)
    remaining_ss_base = [ ss_wage_base - box3, 0.0 ].max
    box7 = [ ss_tips_base, remaining_ss_base ].min.round(2)

    # Box 5: Medicare wages (gross pay, not reduced by pre-tax retirement)
    box5 = medicare_wages_base.round(2)

    # Box 12: Coded entries for retirement contributions
    box12 = build_box12(retirement_total, roth_retirement_total, cash_tips_total, qualified_overtime_total)
    tipped_occupation_codes = tipped_occupation_codes_for(employee)

    # Box 13: Checkboxes
    has_retirement_plan = (employee.retirement_rate.to_f > 0 || employee.roth_retirement_rate.to_f > 0)

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

      # Box 12: Coded amounts (D=401k, AA=Roth 401k)
      box12: box12,
      box14b_tipped_occupation_codes: tipped_occupation_codes,

      # Box 13: Checkboxes
      box13_retirement_plan: has_retirement_plan,
      box13_statutory_employee: false,
      box13_third_party_sick_pay: false,

      # Non-taxable pay (informational)
      non_taxable_total: non_taxable_total.round(2),

      missing_committed_tax_bases: sums&.missing_tax_base_count.to_i.positive?,
      missing_tip_classification: sums&.missing_tip_classification_count.to_i.positive?,
      missing_qualified_overtime: sums&.missing_qualified_overtime_count.to_i.positive?,

      has_missing_ssn: !employee.valid_filing_ssn?,
      has_missing_address: missing_employee_address?(employee)
    }
  end

  def build_box12(retirement_total, roth_retirement_total, cash_tips_total, qualified_overtime_total)
    entries = []
    entries << { code: "D", description: "401(k) elective deferrals", amount: retirement_total.round(2) } if retirement_total > 0
    entries << { code: "AA", description: "Roth 401(k) contributions", amount: roth_retirement_total.round(2) } if roth_retirement_total > 0
    if year >= 2026
      entries << { code: "TP", description: "Cash tips reported to employer", amount: cash_tips_total.round(2) } if cash_tips_total.nonzero?
      entries << { code: "TT", description: "Qualified overtime compensation", amount: qualified_overtime_total.round(2) } if qualified_overtime_total.nonzero?
    end
    entries
  end

  def tipped_occupation_codes_for(employee)
    return [] if year < 2026

    employee.employee_tipped_occupations
            .select { |occupation| occupation.effective_from <= year_range.end && (occupation.effective_to.nil? || occupation.effective_to >= year_range.begin) }
            .map(&:occupation_code)
            .uniq
            .sort
            .first(2)
  end

  def compliance_issues(rows)
    issues = []
    issues << "Employer EIN is missing" if company.ein.blank?
    issues << "Employer address is missing" if missing_employer_address?

    missing_ssn = rows.select { |r| r[:has_missing_ssn] }
    issues << "#{missing_ssn.count} employee(s) missing SSN" if missing_ssn.any?

    missing_employee_address = rows.count { |r| r[:has_missing_address] }
    issues << "#{missing_employee_address} employee(s) missing address" if missing_employee_address.positive?

    missing_bases = rows.count { |r| r[:missing_committed_tax_bases] }
    issues << "#{missing_bases} employee(s) have legacy payroll rows without committed taxable wage bases" if missing_bases.positive?

    if year >= 2026
      missing_tip_classification = rows.count { |r| r[:missing_tip_classification] }
      issues << "#{missing_tip_classification} employee(s) have reported tips without 2026 cash-tip classification" if missing_tip_classification.positive?

      missing_qualified_overtime = rows.count { |r| r[:missing_qualified_overtime] }
      issues << "#{missing_qualified_overtime} employee(s) have overtime without stored qualified-overtime compensation" if missing_qualified_overtime.positive?

      missing_occupation_codes = rows.count do |row|
        row[:reported_tips_total].to_f.positive? && row[:box14b_tipped_occupation_codes].blank?
      end
      issues << "#{missing_occupation_codes} tipped employee(s) missing Treasury tipped occupation code" if missing_occupation_codes.positive?
    end

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
