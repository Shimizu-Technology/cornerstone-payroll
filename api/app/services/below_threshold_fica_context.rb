# frozen_string_literal: true

# A current-check proof of threshold independence, never a proof of old bases.
# Call only under the existing Company -> PayPeriod financial locks.
class BelowThresholdFicaContext
  VERSION = 1
  MODE = "calculable_below_thresholds"
  NOTE = "Prior-period void history needs accountant review; this paycheck's Social Security/Medicare is unaffected because the conservative annual wage bounds are within the limits. Historical tax and filing review remains open.".freeze
  TAX_FIELDS = %w[social_security_tax employer_social_security_tax medicare_tax employer_medicare_tax].freeze
  SOURCE_FIELDS = (EmployeeYearFicaContext::FINGERPRINT_FIELDS + %w[
    company_id employee_id employment_type voided voided_at void_reason payroll_reversed_at
    payroll_reversed_by_id payroll_reversal_reason financial_correction_origin_item_id
  ]).freeze
  PERIOD_FIELDS = %w[id company_id status pay_date parallel_run correction_status corrects_pay_period_id source_pay_period_id].freeze

  def initialize(employee:, company:, year:, excluding_pay_period_id: nil)
    @employee, @company, @year, @excluding_pay_period_id = employee, company, year, excluding_pay_period_id
  end

  def applicable?
    periods = PayPeriod.where(company: company, status: "committed", pay_date: year_range)
    periods = periods.where.not(id: excluding_pay_period_id) if excluding_pay_period_id
    PayrollItem.where(company: company, employee_id: candidate_employee_ids, pay_period_id: periods.select(:id))
      .where.not(employment_type: "contractor").left_joins(:legacy_disposition, :pay_period)
      .where("payroll_items.payroll_reversed_at IS NOT NULL OR pay_periods.correction_status = 'voided' OR payroll_item_legacy_dispositions.id IS NOT NULL").exists?
  end

  def snapshot(current_item:, rules:, lock_rules: false)
    if lock_rules
      AnnualTaxConfig.where(tax_year: year).order(:id).lock("FOR SHARE").load
      TaxTable.for_year(year).order(:id).lock("FOR SHARE").load
    end
    verified = PayrollFicaLegacyRecovery.new(company: company, year: year).verified_year_rules
    hold!("Verified year rules unavailable or inconsistent") unless verified && rules_agree?(rules, verified)
    gross = amount(current_item.gross_pay)
    tips = amount(current_item.cash_tips_reported)
    if current_item.correction_entry? || gross.negative? || tips.negative? || tips > gross || tips != amount(current_item.reported_tips) || current_item.employment_type == "contractor"
      hold!("Signed corrections or tip reclassifications require reviewed annual reconciliation")
    end
    review = EmployeeYearFicaSourceReview.where(company: company, employee: employee, tax_year: year).order(:id).last
    through = [ current_item.pay_period.pay_date, *candidates.map { |item| item.pay_period.pay_date } ].max
    hold!("External/predecessor wage completeness needs an attributable source review") unless review && review.through_pay_date >= through
    # Imported checks lack finalized SS/Medicare wage/tip bases. Do not treat
    # gross, a tax inversion, or an inactive import as proof of those amounts.
    if HistoricalPaycheck.where(company: company, employee_id: [ nil, *candidate_employee_ids ], pay_date: year_range).exists?
      hold!("Imported paycheck FICA source completeness requires separately reviewed reconciliation")
    end
    if PayrollGoLiveReview.where(company: company).exists?
      hold!("Successor/predecessor import mapping requires separately reviewed reconciliation")
    end
    hold!("No disputed financial history for the below-threshold path") unless disputed_history?
    bounds = { ss: 0.to_d, medicare: 0.to_d }
    candidates.each do |item|
      validate_candidate!(item, verified)
      # Count both original and replacement, including disposed/reversed rows.
      maximum = [ amount(item.gross_pay), amount(item.medicare_taxable_wages || item.gross_pay),
        amount(item.social_security_taxable_wages || 0) + amount(item.social_security_taxable_tips || 0), 0.to_d ].max
      bounds[:ss] += maximum
      bounds[:medicare] += maximum
    end
    balances.each do |balance|
      validate_opening!(balance, verified)
      maximum = [ amount(balance.gross_pay), amount(balance.medicare_taxable_wages),
        amount(balance.social_security_taxable_wages) + amount(balance.social_security_taxable_tips), 0.to_d ].max
      bounds[:ss] += maximum
      bounds[:medicare] += maximum
    end
    bounds[:ss] += amount(review.external_ss_wage_bound) + gross
    bounds[:medicare] += amount(review.external_medicare_wage_bound) + gross
    if bounds[:ss] > amount(verified.fetch("social_security_wage_base")) || bounds[:medicare] > amount(verified.fetch("additional_medicare_threshold"))
      hold!("Conservative annual wages exceed a FICA threshold")
    end
    source_digest = FicaBasisEvidence.digest([
      candidates.map { |item| [ item.attributes.slice(*SOURCE_FIELDS), FicaBasisEvidence.rule_evidence(item),
        item.pay_period.attributes.slice(*PERIOD_FIELDS), item.legacy_disposition&.attributes, item.fica_basis_proof&.evidence ] },
      balances.map { |balance| [ balance.attributes, balance.historical_ytd_bridge.attributes ] },
      review.attributes, candidate_employees.map { |person| person.attributes.slice("id", "company_id", "previous_employee_id", "employment_type") }
    ])
    { "version" => VERSION, "mode" => MODE, "year" => year, "employee_id" => employee.id,
      "history_review_open" => true, "filing_review_open" => true, "note" => NOTE,
      "source_digest" => source_digest, "rule_digest" => FicaBasisEvidence.digest(verified),
      "bounds" => FicaBasisEvidence.normalize(bounds.stringify_keys),
      "current_wages" => FicaBasisEvidence.normalize({ "medicare" => gross, "ss_wages" => gross - tips, "ss_tips" => tips }) }
  rescue ArgumentError, TypeError, KeyError => error
    raise error if error.is_a?(EmployeeYearFicaContext::UnreconciledLedgerError)
    hold!("Missing, non-finite or contradictory FICA source amounts")
  end

  private

  attr_reader :employee, :company, :year, :excluding_pay_period_id

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def candidate_employees
    @candidate_employees ||= begin
      people = [ employee ]
      while (previous_id = people.last.previous_employee_id)
        hold!("Cyclic predecessor employee history") if people.any? { |person| person.id == previous_id }
        previous = Employee.find_by(id: previous_id, company_id: company.id)
        hold!("Unknown predecessor employee wages") unless previous
        people << previous
      end
      people
    end
  end

  def candidate_employee_ids
    candidate_employees.map(&:id)
  end

  def candidates
    @candidates ||= begin
      periods = PayPeriod.where(company: company, status: "committed", pay_date: year_range)
      periods = periods.where.not(id: excluding_pay_period_id) if excluding_pay_period_id
      PayrollItem.where(company: company, employee_id: candidate_employee_ids, pay_period_id: periods.select(:id))
        .where.not(employment_type: "contractor").includes(:pay_period, :legacy_disposition, :fica_basis_proof).order(:id).to_a
    end
  end

  def balances
    # Count every applied revision, deliberately retaining overlapping balances.
    @balances ||= HistoricalEmployeeYtdBalance.joins(:historical_ytd_bridge)
      .where(company: company, employee_id: candidate_employee_ids, tax_year: year, historical_ytd_bridges: { status: "applied" })
      .includes(:historical_ytd_bridge).order(:id).to_a
  end

  def disputed_history?
    candidates.any? { |item| !item.payroll_included? || item.legacy_disposition.present? }
  end

  def validate_candidate!(item, rules)
    gross = amount(item.gross_pay)
    tips = amount(item.cash_tips_reported || item.reported_tips)
    hold!("Contradictory or signed historical wages/tips") if item.correction_entry? || gross.negative? || tips.negative? || tips > gross
    hold!("Contradictory recorded Medicare wages") if item.medicare_taxable_wages && amount(item.medicare_taxable_wages) != gross
    if item.cash_tips_reported && amount(item.cash_tips_reported) != amount(item.reported_tips)
      hold!("Contradictory recorded tips")
    end
    captured = FicaBasisEvidence.rule_evidence(item)
    hold!("Captured rules contradict verified year rules") unless rules_agree?(captured, rules, partial: true)
    expected = { social_security_taxable_wages: gross - tips, social_security_taxable_tips: tips,
      medicare_taxable_wages: gross, additional_medicare_taxable_wages: 0.to_d }
    expected.each do |field, value|
      recorded = item.public_send(field)
      hold!("Recorded historical FICA bases contradict uncapped wages") if recorded && amount(recorded) != value
    end
    if (proof = item.fica_basis_proof)
      proven = FicaBasisEvidence.verified_bases(proof.evidence, row: item, year: year, employee_id: item.employee_id)
      unless proven && expected.all? { |field, value| proven.fetch(field) == value }
        hold!("Reviewed historical FICA proof contradicts uncapped wages")
      end
    end
    components = FicaBasisEvidence.components(expected, rules)
    TAX_FIELDS.each do |field|
      hold!("Stored historical FICA taxes contradict uncapped wages") unless amount(item.public_send(field)) == components.fetch(field.to_sym)
    end
    # Legacy additional Medicare was nullable; a missing zero is harmless only
    # with both complete employee/employer Medicare taxes corroborating zero.
    if item.additional_medicare_tax && amount(item.additional_medicare_tax) != 0
      hold!("Stored historical Additional Medicare exposure")
    end
  end

  def validate_opening!(balance, rules)
    gross = amount(balance.medicare_taxable_wages)
    wages, tips = amount(balance.social_security_taxable_wages), amount(balance.social_security_taxable_tips)
    if [ gross, wages, tips, amount(balance.gross_pay), amount(balance.reported_tips) ].any?(&:negative?) ||
        wages + tips != gross || tips != amount(balance.reported_tips) || gross != amount(balance.gross_pay)
      hold!("Contradictory opening/predecessor FICA wages")
    end
    if amount(balance.social_security_tax) != (gross * amount(rules.fetch("social_security_rate"))).round(2, BigDecimal::ROUND_HALF_UP) ||
        amount(balance.medicare_tax) != (gross * amount(rules.fetch("medicare_rate"))).round(2, BigDecimal::ROUND_HALF_UP)
      hold!("Opening FICA taxes require reviewed reconciliation")
    end
  end

  def rules_agree?(captured, verified, partial: false)
    return false unless captured.is_a?(Hash)
    return false if captured.key?("tax_year") && captured["tax_year"].to_s != year.to_s
    FicaBasisEvidence::RULE_FIELDS.all? do |field|
      (partial && !captured.key?(field)) || amount(captured.fetch(field)) == amount(verified.fetch(field))
    end
  end

  def amount(value)
    FicaBasisEvidence.amount(value)
  end

  def hold!(reason)
    raise EmployeeYearFicaContext::UnreconciledLedgerError, "#{reason}. Hold payroll for an explicit reviewed annual reconciliation."
  end
end
