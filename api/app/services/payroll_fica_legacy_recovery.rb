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

  def inventory(employee_ids: nil)
    ids = normalize_employee_ids(employee_ids)
    inventory_for(employee_plans(ids), employee_ids: ids)
  end

  def apply!(actor:, review_reference:, expected_digest:, employee_ids: nil)
    unless actor&.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(company.id)
      raise ArgumentError, "An authorized payroll administrator is required"
    end
    unless review_reference.to_s.strip.length.between?(10, 1000)
      raise ArgumentError, "A review reference of 10–1000 characters is required"
    end
    ApplicationRecord.transaction(requires_new: true) do
      Company.lock.find(company.id)
      PayPeriod.where(company_id: company.id, pay_date: year_range).order(:id).lock.load
      AnnualTaxConfig.where(tax_year: year).order(:id).lock("FOR SHARE").load
      TaxTable.for_year(year).order(:id).lock("FOR SHARE").load
      self.class.new(company: company, year: year).apply_locked!(actor: actor, review_reference: review_reference.strip,
        expected_digest: expected_digest, employee_ids: normalize_employee_ids(employee_ids))
    end
  end

  protected

  def apply_locked!(actor:, review_reference:, expected_digest:, employee_ids:)
    entries = employee_plans(employee_ids)
    plan = inventory_for(entries, employee_ids: employee_ids)
    unless expected_digest.present? && ActiveSupport::SecurityUtils.secure_compare(plan[:plan_digest], expected_digest.to_s)
      raise ArgumentError, "FICA inventory changed; run a new dry-run, review it and apply its plan digest"
    end

    affected = entries.select { |entry| entry.fetch(:proofs).any? }
    created = affected.sum do |entry|
      entry.fetch(:proofs).each do |id, evidence|
        PayrollItemFicaBasisProof.create!(payroll_item_id: id, company: company, created_by: actor, tax_year: year,
          plan_digest: plan[:plan_digest], review_reference: review_reference, evidence: evidence)
      end.size
    end
    employees = company.employees.where(id: affected.pluck(:employee_id)).index_by(&:id)
    ledgers = EmployeeYearFicaContext.ledger_rows(EmployeeYearFicaContext.reportable_items(company: company,
      employee_ids: employees.keys, year: year)).order(:id).group_by(&:employee_id)
    openings = EmployeeYearFicaContext.opening_balances(company: company, employee_ids: employees.keys, year: year).group_by(&:employee_id)
    affected.each do |entry|
      employee_id = entry.fetch(:employee_id)
      ledger = ledgers.fetch(employee_id)
      context = verification_context(employees.fetch(employee_id), ledger, openings[employee_id]&.first)
      probe_ordinary!(context)
      verify_history!(context, ledger)
    rescue EmployeeYearFicaContext::UnreconciledLedgerError => error
      raise EmployeeYearFicaContext::UnreconciledLedgerError, "#{verification_location(employee_id, ledger.last.id)}: #{error.message}"
    end
    plan.merge(applied_proofs: created)
  end

  private

  attr_reader :company, :year

  def normalize_employee_ids(employee_ids)
    return if employee_ids.nil?

    ids = Array(employee_ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
    unless company.employees.where(id: ids).count == ids.size
      raise ArgumentError, "Every selected employee must belong to the company"
    end
    ids
  end

  def inventory_for(plans, employee_ids:)
    counts = plans.flat_map { |plan| plan[:rows] }.group_by { |row| row[:status] }.transform_values(&:size)
    counts = %i[complete proven recoverable held calculable_below_thresholds].to_h { |key| [ key, counts.fetch(key.to_s, 0) ] }
    data = { company_id: company.id, tax_year: year, counts: counts,
      employee_year_counts: plans.group_by { |plan| plan[:status] }.transform_values(&:size),
      employee_years: plans.map { |plan| plan.except(:proofs) } }
    data[:employee_ids] = employee_ids if employee_ids
    data.merge(plan_digest: FicaBasisEvidence.digest(data))
  end

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end

  def employee_plans(employee_ids)
    employees = company.employees
    employees = employees.where(id: employee_ids) if employee_ids
    scope = EmployeeYearFicaContext.reportable_items(company: company,
      employee_ids: employees.select(:id), year: year)
    ledgers = EmployeeYearFicaContext.ledger_rows(scope).order(:employee_id, :id).to_a.group_by(&:employee_id)
    historical = PayrollItem.where(company_id: company.id, employee_id: employees.select(:id), employment_type: %w[hourly salary],
      pay_period_id: PayPeriod.where(company_id: company.id, status: "committed", parallel_run: false, pay_date: year_range).select(:id))
      .pluck(:employee_id, :id, :correction_for_payroll_item_id, :gross_pay).group_by(&:first)
    ids = (ledgers.keys | historical.keys).sort
    balances = EmployeeYearFicaContext.opening_balances(company: company, year: year, employee_ids: ids).to_a.group_by(&:employee_id)
    people = employees.where(id: ids).index_by(&:id)
    ids.map do |employee_id|
      plan_employee(people.fetch(employee_id), ledgers.fetch(employee_id, []), balances[employee_id]&.first,
        historical.fetch(employee_id, []))
    end
  end

  def plan_employee(employee, ledger, opening, history)
    employee_id = employee.id
    ledger = ledger.sort_by(&:id)
    ids = ledger.map(&:id)
    historical_ids = history.map { |row| row[1] }.sort
    history_reason = if historical_ids != ids
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
    baseline = verification_context(employee, ledger, opening)
    initial_states = ledger.map { |row| classify(row, ledger, opening, upper_bound, history_reason, baseline) }
    proofs = {}
    reports = ledger.zip(initial_states).map do |row, state|
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
    result = { employee_id: employee_id, tax_year: year, status: "ready", rows: reports, proofs: proofs }

    result.merge!(history_review_open: true, filing_review_open: true) if (historical_ids - ids).any?

    simulated = with_planned_proofs(ledger, proofs)
    context = proofs.empty? ? baseline : verification_context(employee, simulated, opening)
    # Recheck dependent rows against the whole candidate set. This pass never
    # adds more candidates, and the ordinary replay uses its own ledger order.
    reports.zip(simulated).each do |report, row|
      next if proofs.empty? || report[:status] != "held" || !captured_context_proven?(row, context, year_rules)

      report.replace(proven_context.merge(payroll_item_id: row.id))
    end
    raise EmployeeYearFicaContext::UnreconciledLedgerError, history_reason if invalid_source

    probe_ordinary!(context)
    if (held_row = reports.find { |report| report[:status] == "held" })
      raise EmployeeYearFicaContext::UnreconciledLedgerError, "Payroll item ##{held_row[:payroll_item_id]}: #{held_row[:reason]}"
    end
    verify_history!(context, simulated)
    result
  rescue EmployeeYearFicaContext::UnreconciledLedgerError => error
    reason = "#{verification_location(employee_id, ids.last)}: #{error.message}"
    restored = ledger.zip(initial_states).map do |row, state|
      state = held(reason) if state[:status] == "recoverable"
      state.merge(payroll_item_id: row.id)
    end
    result.merge!(status: "held", reason: reason, rows: restored, proofs: {})
    if !invalid_source && baseline_probe_succeeds?(baseline)
      result
    else
      bounded_inventory(result, employee)
    end
  end

  def baseline_probe_succeeds?(context)
    probe_ordinary!(context)
    true
  rescue EmployeeYearFicaContext::UnreconciledLedgerError
    false
  end

  def verification_context(employee, ledger, opening)
    VerificationContext.new(employee: employee, company: company, year: year, rows: ledger, opening_balance: opening)
  end

  def with_planned_proofs(ledger, proofs)
    return ledger if proofs.empty?

    # The live fingerprint hashes the JSONB key order returned by PostgreSQL.
    connection = PayrollItem.connection
    persisted_order = JSON.parse(connection.select_value("SELECT #{connection.quote(proofs.to_json)}::jsonb"))
    ledger.map do |row|
      proof = persisted_order[row.id.to_s]
      proof ? PayrollItem.instantiate(row.attributes.merge("recorded_legacy_fica_proof" => proof)) : row
    end
  end

  def verify_history!(context, ledger)
    ledger.each do |row|
      next if captured_rules_agree?(row, year_rules)

      raise EmployeeYearFicaContext::UnreconciledLedgerError, "Payroll item ##{row.id}: captured year rules contradict verified year rules."
    end
    context.verify_recorded_history!(rules: year_rules)
  end

  def probe_ordinary!(context)
    error_class = EmployeeYearFicaContext::UnreconciledLedgerError
    raise error_class, "Verified year rules unavailable or inconsistent" unless year_rules

    [ 0, 1 ].each do |wages|
      probe = context.recorded_increment(wages_delta: wages, tips_delta: 0, rules: year_rules)
      unless probe.fetch(:additional_medicare_taxable_wages).between?(0, wages)
        raise error_class, "Annual Additional Medicare bases need an explicit reviewed reconciliation beyond this check's wages."
      end
    end
  end

  def verification_location(employee_id, last_item_id)
    location = "Employee ##{employee_id}"
    last_item_id ? "#{location} through payroll item ##{last_item_id}" : location
  end

  def bounded_inventory(result, employee)
    context = BelowThresholdFicaContext.new(employee: employee, company: company, year: year)
    return result unless context.applicable?

    probe = PayrollItem.new(employee: employee, company: company, employment_type: "hourly", gross_pay: 0,
      cash_tips_reported: 0, reported_tips: 0, pay_period: PayPeriod.new(pay_date: Date.new(year, 1, 1)))
    evidence = context.snapshot(current_item: probe, rules: year_rules)
    result[:rows].each do |report|
      next unless report[:status] == "held"

      report[:status] = "calculable_below_thresholds"
      report[:reason] = "Current ordinary checks may calculate only while their added wages keep both bounds within limits and their pay date is covered by the latest source review; history review remains open"
    end
    # Capacity at zero new wages, not clearance for a check of any size.
    result.except(:reason).merge(status: "calculable_below_thresholds", history_review_open: true, filing_review_open: true,
      conservative_history_bounds: evidence.fetch("bounds"), source_digest: evidence.fetch("source_digest"))
  rescue EmployeeYearFicaContext::UnreconciledLedgerError => error
    result.merge(history_review_open: true, filing_review_open: true, below_threshold_reason: error.message)
  end

  def classify(row, ledger, opening, upper_bound, history_reason, context)
    missing = FicaBasisEvidence::BASE_FIELDS.reject { |field| field == "medicare_taxable_wages" }.any? { |field| row.public_send(field).nil? }
    rules = year_rules
    return held("Verified year rules unavailable or inconsistent") unless rules
    return held("Captured year rules contradict verified year rules; reviewed reconciliation required") unless captured_rules_agree?(row, rules)
    return { status: "complete", reason: "Recorded SS and Additional Medicare bases present" } unless missing
    if row[:recorded_legacy_fica_proof].present?
      valid = FicaBasisEvidence.verified_bases(row[:recorded_legacy_fica_proof], row: row, year: year, employee_id: row.employee_id)
      return valid ? { status: "proven", reason: "Reviewed proof matches financial history" } : held("Reviewed proof no longer matches financial history; separate reconciliation required")
    end
    return held(history_reason) if history_reason&.start_with?("Missing", "Opening")
    return proven_context if captured_context_proven?(row, context, rules)
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

  def captured_context_proven?(row, context, rules)
    rules && captured_rules_agree?(row, rules) && context.verified_basis?(row, rules)
  end

  def proven_context
    { status: "proven", reason: "Captured annual context and stored components remain verified" }
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
