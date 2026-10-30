# frozen_string_literal: true

# An explicit release operation. Inventory/dry-run only read; apply appends
# reviewed proof records under the same Company -> PayPeriod financial locks.
class PayrollFicaLegacyRecovery
  def initialize(company:, year:)
    @company = company
    @year = Integer(year)
  end

  def verified_year_rules
    year_rules
  end

  def inventory
    plans = employee_plans
    counts = plans.flat_map { |plan| plan[:rows] }.group_by { |row| row[:status] }.transform_values(&:size)
    counts = %i[complete proven recoverable held calculable_below_thresholds].to_h { |key| [ key, counts.fetch(key.to_s, 0) ] }
    data = { company_id: company.id, tax_year: year, counts: counts,
      employee_year_counts: plans.group_by { |plan| plan[:status] }.transform_values(&:size),
      employee_years: plans.map { |plan| plan.except(:proofs) } }
    data.merge(plan_digest: FicaBasisEvidence.digest(data))
  end

  def apply!(actor:, review_reference:, expected_digest:)
    unless actor&.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(company.id)
      raise ArgumentError, "An authorized payroll administrator is required"
    end
    unless review_reference.to_s.strip.length.between?(10, 1000)
      raise ArgumentError, "A review reference of 10–1000 characters is required"
    end
    ApplicationRecord.transaction do
      Company.lock.find(company.id)
      PayPeriod.where(company_id: company.id, pay_date: year_range).order(:id).lock.load
      AnnualTaxConfig.where(tax_year: year).order(:id).lock("FOR SHARE").load
      TaxTable.for_year(year).order(:id).lock("FOR SHARE").load
      fresh = self.class.new(company: company, year: year)
      plan = fresh.inventory
      unless expected_digest.present? && ActiveSupport::SecurityUtils.secure_compare(plan[:plan_digest], expected_digest.to_s)
        raise ArgumentError, "FICA inventory changed; run a new dry-run, review it and apply its plan digest"
      end
      created = fresh.send(:employee_plans).sum do |entry|
        entry.fetch(:proofs).each do |id, evidence|
          PayrollItemFicaBasisProof.create!(payroll_item_id: id, company: company, created_by: actor, tax_year: year,
            plan_digest: plan[:plan_digest], review_reference: review_reference.strip, evidence: evidence)
        end.size
      end
      plan.merge(applied_proofs: created)
    end
  end

  private

  attr_reader :company, :year

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def employee_plans
    @employee_plans ||= begin
      scope = EmployeeYearFicaContext.reportable_items(company: company,
        employee_ids: company.employees.select(:id), year: year)
      rows = EmployeeYearFicaContext.ledger_rows(scope).order(:employee_id, :id).to_a
      balances = EmployeeYearFicaContext.opening_balances(company: company, year: year,
        employee_ids: rows.map(&:employee_id).uniq).to_a.group_by(&:employee_id)
      historical = PayrollItem.where(company_id: company.id, employment_type: %w[hourly salary],
        pay_period_id: PayPeriod.where(company_id: company.id, status: "committed", parallel_run: false, pay_date: year_range).select(:id))
        .pluck(:employee_id, :id, :correction_for_payroll_item_id, :gross_pay).group_by(&:first)
      ledgers = rows.group_by(&:employee_id)
      (ledgers.keys | historical.keys).sort.map do |employee_id|
        ledger = ledgers.fetch(employee_id, [])
        opening = balances[employee_id]&.first
        plan_employee(employee_id, ledger, opening, historical.fetch(employee_id, []))
      end
    end
  end

  def plan_employee(employee_id, ledger, opening, history)
    ids = ledger.map(&:id).sort
    history_reason = if history.map { |row| row[1] }.sort != ids
      "Excluded or financially reversed history requires reviewed reconciliation"
    elsif history.any? { |row| row[2].present? || row[3].nil? || row[3].negative? }
      "Signed correction history requires reviewed correction reconciliation"
    end
    invalid_source = ledger.any? do |row|
      row.gross_pay.nil? || %i[gross_pay medicare_taxable_wages cash_tips_reported reported_tips].any? do |field|
        value = row.public_send(field)
        value && !value.finite?
      end
    end
    history_reason = "Missing or non-finite source wages/tips require reviewed reconciliation" if invalid_source
    if opening && (opening.medicare_taxable_wages.to_d.negative? ||
        opening.social_security_taxable_wages.to_d + opening.social_security_taxable_tips.to_d > opening.medicare_taxable_wages.to_d ||
        opening.social_security_taxable_tips.to_d > opening.reported_tips.to_d)
      history_reason = "Opening balance context requires reviewed reconciliation"
    end
    upper_bound = invalid_source ? 0.to_d : ledger.sum(0.to_d) { |row| [ (row.medicare_taxable_wages || row.gross_pay).to_d, 0.to_d ].max } +
      opening&.medicare_taxable_wages.to_d
    dependency_digest = FicaBasisEvidence.ledger_digest(ledger)
    opening_digest = FicaBasisEvidence.opening_digest(opening)
    proofs = {}
    reports = ledger.map do |row|
      state = classify(row, ledger, opening, upper_bound, history_reason)
      if state[:status] == "recoverable"
        proof = { "version" => 1, "year" => year, "employee_id" => employee_id,
          "row_digest" => FicaBasisEvidence.row_digest(row), "dependency_through_id" => ids.max, "dependency_count" => ids.size,
          "dependency_digest" => dependency_digest, "opening_digest" => opening_digest,
          "bases" => FicaBasisEvidence.normalize(state.fetch(:bases).stringify_keys),
          "rules" => state.fetch(:rules), "derivation" => "uncapped nonnegative ordinary history; exact stored employee/employer tax reconciliation" }
        proofs[row.id] = proof
        state = state.except(:bases, :rules).merge(proposed_bases: proof["bases"], verified_rules: proof["rules"],
          stored_taxes: FicaBasisEvidence.normalize(row.attributes.slice("social_security_tax", "employer_social_security_tax",
            "medicare_tax", "employer_medicare_tax", "additional_medicare_tax")), evidence_digest: FicaBasisEvidence.digest(proof))
      end
      state.merge(payroll_item_id: row.id)
    end
    result = { employee_id: employee_id, tax_year: year,
      status: reports.any? { |row| row[:status] == "held" } ? "held" : "ready",
      rows: reports, proofs: proofs }
    if history_reason || ledger.any? { |row| row[:recorded_annual_fica_context].is_a?(Hash) && row[:recorded_annual_fica_context]["history_review_open"] }
      begin
        employee = Employee.find(employee_id)
        probe = PayrollItem.new(employee: employee, company: company, employment_type: "hourly", gross_pay: 0,
          cash_tips_reported: 0, reported_tips: 0, pay_period: PayPeriod.new(pay_date: Date.new(year, 1, 1)))
        context = BelowThresholdFicaContext.new(employee: employee, company: company, year: year)
        evidence = context.snapshot(current_item: probe, rules: year_rules)
        reports.each do |report|
          if report[:status] == "held"
            report[:status] = "calculable_below_thresholds"
            report[:reason] = "Current ordinary checks may calculate only while their added wages keep both bounds within limits and their pay date is covered by the latest source review; history review remains open"
          end
        end
        # Capacity at zero new wages, not clearance for a check of any size.
        result.merge!(status: "calculable_below_thresholds", history_review_open: true, filing_review_open: true,
          conservative_history_bounds: evidence.fetch("bounds"), source_digest: evidence.fetch("source_digest"))
        result[:proofs] = {}
      rescue EmployeeYearFicaContext::UnreconciledLedgerError => error
        result.merge!(status: "held", history_review_open: true, filing_review_open: true, reason: error.message)
      end
    end
    result
  end

  def classify(row, ledger, opening, upper_bound, history_reason)
    missing = FicaBasisEvidence::BASE_FIELDS.reject { |field| field == "medicare_taxable_wages" }.any? { |field| row.public_send(field).nil? }
    return { status: "complete", reason: "Recorded SS and Additional Medicare bases present" } unless missing
    if row[:recorded_legacy_fica_proof].present?
      valid = FicaBasisEvidence.verified_bases(row[:recorded_legacy_fica_proof], row: row, year: year, employee_id: row.employee_id)
      return valid ? { status: "proven", reason: "Reviewed proof matches financial history" } : held("Reviewed proof no longer matches financial history; separate reconciliation required")
    end
    return held(history_reason) if history_reason&.start_with?("Missing", "Opening")
    rules = year_rules
    return held("Verified year rules unavailable or inconsistent") unless rules
    return held("Captured year rules contradict verified year rules; reviewed reconciliation required") unless captured_rules_agree?(row, rules)
    if captured_context_proven?(row, ledger, opening, rules)
      return { status: "proven", reason: "Captured annual context and stored components remain verified" }
    end
    return held(history_reason) if history_reason
    gross = (row.medicare_taxable_wages || row.gross_pay).to_d
    tips = (row.cash_tips_reported || row.reported_tips).to_d
    return held("Gross/Medicare wages or reported tips are contradictory") if gross.negative? || tips.negative? || tips > gross || gross != row.gross_pay
    cap = FicaBasisEvidence.amount(rules.fetch("social_security_wage_base"))
    wages = row.social_security_taxable_wages
    taxable_tips = row.social_security_taxable_tips
    if upper_bound <= cap
      if (wages && wages != gross - tips) || (taxable_tips && taxable_tips != tips)
        return held("Known SS bases contradict uncapped ordinary wages/tips; reviewed reconciliation required")
      end
      wages ||= gross - tips
      taxable_tips ||= tips
    else
      # A zero actual component is provable without inverting rounded tax.
      wages ||= 0.to_d if gross == tips
      taxable_tips ||= 0.to_d if tips.zero?
      return held("Annual SS cap reached; missing wage/tip allocation cannot be proven from rounded tax") if wages.nil? || taxable_tips.nil?
    end
    additional = row.additional_medicare_taxable_wages
    if upper_bound <= FicaBasisEvidence.amount(rules.fetch("additional_medicare_threshold")) && additional&.nonzero?
      return held("Known Additional Medicare base contradicts below-threshold ordinary history; reviewed reconciliation required")
    end
    if additional.nil?
      return held("Additional Medicare threshold reached; missing base requires reviewed allocation") if upper_bound > FicaBasisEvidence.amount(rules.fetch("additional_medicare_threshold")) && gross.positive?
      additional = 0.to_d
    end
    bases = { social_security_taxable_wages: wages, social_security_taxable_tips: taxable_tips,
      medicare_taxable_wages: gross, additional_medicare_taxable_wages: additional }
    if wages.negative? || taxable_tips.negative? || wages + taxable_tips > gross || taxable_tips > tips || additional.negative? || additional > gross
      return held("Recorded bases contradict actual wages/tips; reviewed reconciliation required")
    end
    known_ss = ledger.sum(0.to_d) { |item| item.social_security_taxable_wages.to_d + item.social_security_taxable_tips.to_d } +
      opening&.social_security_taxable_wages.to_d + opening&.social_security_taxable_tips.to_d
    return held("Recorded annual SS bases already exceed the cap") if known_ss > cap
    components = FicaBasisEvidence.components(bases, rules)
    return held("Stored employee/employer FICA taxes do not reconcile exactly with derivable bases and year rules") unless FicaBasisEvidence.matches_recorded?(row, components)
    { status: "recoverable", reason: "Derivable bases reconcile exactly with stored employee/employer taxes", bases: bases, rules: rules }
  end

  def captured_rules_agree?(row, rules)
    captured = FicaBasisEvidence.rule_evidence(row)
    return false if captured.key?("tax_year") && Integer(captured["tax_year"].to_s) != year
    FicaBasisEvidence::RULE_FIELDS.all? do |field|
      !captured.key?(field) || FicaBasisEvidence.amount(captured[field]) == FicaBasisEvidence.amount(rules.fetch(field))
    end
  rescue ArgumentError, TypeError, KeyError
    false
  end

  def captured_context_proven?(row, ledger, opening, rules)
    return false unless row[:recorded_annual_fica_context].is_a?(Hash)
    return false if row.additional_medicare_taxable_wages.nil? && row.additional_medicare_tax.nil?
    @captured_contexts ||= {}
    context = @captured_contexts[row.employee_id] ||= EmployeeYearFicaContext.new(
      employee: Employee.new(id: row.employee_id, company: company), company: company, year: year, rows: ledger, opening_balance: opening)
    recovered = context.send(:recovered_bases, row, rules)
    FicaBasisEvidence.matches_recorded?(row, recovered)
  rescue EmployeeYearFicaContext::UnreconciledLedgerError
    false
  end

  def held(reason)
    { status: "held", reason: reason }
  end

  def year_rules
    # Use actual year configurations, never a nearest year or current-year fallback.
    # Multiple configured engines must agree before automatic reconciliation.
    return @year_rules if defined?(@year_rules)

    @year_rules = nil
    return unless AnnualTaxConfig.verified_for_year?(year)

    @year_rules = begin
      tables = TaxTable.for_year(year).where(verification_status: "verified").order(:id).to_a
      sources = tables.map { |table| { "engine" => "legacy_tax_table", "id" => table.id, "updated_at" => table.updated_at.iso8601(6) } }
      configs = tables.map do |table|
        { "social_security_wage_base" => table.ss_wage_base, "social_security_rate" => table.ss_rate,
          "medicare_rate" => table.medicare_rate, "additional_medicare_rate" => table.additional_medicare_rate,
          "additional_medicare_threshold" => table.additional_medicare_threshold }
      end
      if (annual = AnnualTaxConfig.current(year))&.verified?
        sources << { "engine" => "annual_tax_config_v2", "id" => annual.id, "updated_at" => annual.updated_at.iso8601(6),
          "verified_at" => annual.verified_at&.iso8601(6), "verified_by" => annual.verified_by }
        configs << { "social_security_wage_base" => annual.ss_wage_base, "social_security_rate" => annual.ss_rate,
          "medicare_rate" => annual.medicare_rate, "additional_medicare_rate" => annual.additional_medicare_rate,
          "additional_medicare_threshold" => annual.additional_medicare_threshold }
      end
      normalized = configs.map { |rules| FicaBasisEvidence.normalize(rules) }.uniq
      candidate = normalized.sole if normalized.size == 1
      valid = candidate && candidate.values.all? { |value| value.present? && FicaBasisEvidence.amount(value) >= 0 } &&
        FicaBasisEvidence.amount(candidate["social_security_wage_base"]).positive? &&
        FicaBasisEvidence.amount(candidate["additional_medicare_threshold"]) == 200_000
      candidate.merge("source_records" => sources) if valid
    rescue ArgumentError, TypeError
      nil
    end
    @year_rules
  end
end
