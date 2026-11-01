# frozen_string_literal: true

class ImportedPaycheckFicaReconciliation
  def initialize(company:, year:, employee_ids: nil)
    @company, @year = company, Integer(year)
    @employee_ids = employee_ids&.map { |id| Integer(id) }&.uniq&.sort
    if @employee_ids && company.employees.where(id: @employee_ids).count != @employee_ids.size
      raise ArgumentError, "Every selected employee must belong to the company"
    end
  end

  def inventory
    data = { company_id: company.id, tax_year: year, employee_ids: employee_ids, employee_years: employee_plans.map { |plan| plan.except(:proofs) },
      source_digest: FicaBasisEvidence.digest(employee_plans.map { |plan| plan[:rows] }),
      corroboration_tolerance_cents: ImportedPaycheckFicaEvidence::TOLERANCE_CENTS,
      residual_totals_cents: ImportedPaycheckFicaEvidence.residual_totals(employee_plans.map { |plan| plan[:residual_totals_cents] }),
      checks_with_residual: employee_plans.sum { |plan| plan[:checks_with_residual] },
      counts: %w[proven recoverable held].to_h { |status| [ status, employee_plans.sum { |plan| plan[:rows].count { |row| row[:status] == status } } ] } }
    data.merge(plan_digest: FicaBasisEvidence.digest(data))
  end

  def apply!(actor:, review_reference:, expected_digest:)
    ApplicationRecord.transaction do
      Company.lock.find(company.id)
      actor&.lock!
      unless actor&.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(company.id)
        raise ArgumentError, "An authorized payroll administrator is required"
      end
      unless review_reference.to_s.strip.length.between?(10, 1000)
        raise ArgumentError, "A review reference of 10–1000 characters is required"
      end
      range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
      PayPeriod.where(company: company, pay_date: range).order(:id).lock.load
      HistoricalImportBatch.where(company: company).order(:id).lock.load
      AnnualTaxConfig.where(tax_year: year).order(:id).lock("FOR SHARE").load
      TaxTable.for_year(year).order(:id).lock("FOR SHARE").load
      fresh = self.class.new(company: company, year: year, employee_ids: employee_ids)
      plan = fresh.inventory
      unless expected_digest.present? && ActiveSupport::SecurityUtils.secure_compare(plan[:plan_digest], expected_digest.to_s)
        raise ArgumentError, "Imported FICA inventory changed; review a new plan digest"
      end
      created = fresh.send(:employee_plans).sum do |entry|
        entry.fetch(:proofs).each do |id, evidence|
          HistoricalPaycheckFicaBasisProof.create!(historical_paycheck_id: id, company: company, created_by: actor,
            tax_year: year, plan_digest: plan[:plan_digest], review_reference: review_reference.strip, evidence: evidence)
        end.size
      end
      plan.merge(applied_proofs: created)
    end
  end

  private

  attr_reader :company, :year, :employee_ids

  def employee_plans
    @employee_plans ||= begin
      rules = PayrollFicaLegacyRecovery.new(company: company, year: year).verified_year_rules
      scope = HistoricalPaycheck.where(company: company, pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
      scope = scope.where(employee_id: [ nil, *employee_ids ]) if employee_ids
      scope.includes(:employee, :historical_import_batch, :historical_worker, :historical_pay_period, :historical_paycheck_adjustments, :fica_basis_proof)
        .order(:id).group_by(&:employee_id).map { |id, rows| plan_employee(id, rows, rules) }
    end
  end

  def plan_employee(employee_id, rows, rules)
    proofs = {}
    reports = rows.map do |row|
      report = begin
        raise ArgumentError, "Verified year rules unavailable or inconsistent" unless rules
        corroboration = ImportedPaycheckFicaEvidence.corroborate(row, rules)
        residuals = corroboration.fetch(:residual_cents)
        if row.fica_basis_proof
          unless ImportedPaycheckFicaEvidence.verified_bases(row, rules: rules, year: year)
            raise ArgumentError, "Reviewed imported FICA proof no longer matches source or rules"
          end
          { historical_paycheck_id: row.id, status: "proven", reason: "Reviewed imported FICA proof matches source and verified rules",
            residual_cents: residuals }
        else
          evidence = { "version" => ImportedPaycheckFicaEvidence::VERSION, "year" => year, "employee_id" => employee_id,
            "source_digest" => FicaBasisEvidence.digest(ImportedPaycheckFicaEvidence.source(row)),
            "rule_digest" => FicaBasisEvidence.digest(rules), "rules" => rules,
            "bases" => FicaBasisEvidence.normalize(corroboration.fetch(:bases).stringify_keys),
            "corroboration_tolerance_cents" => ImportedPaycheckFicaEvidence::TOLERANCE_CENTS, "residual_cents" => residuals,
            "derivation" => "Full uncapped gross with wages before reported tips; stored employee and present employer FICA taxes each " \
              "within $0.01 of the rule-computed amount (per-check rounding), signed residuals recorded; no rounded-tax inversion" }
          proofs[row.id] = evidence
          { historical_paycheck_id: row.id, status: "recoverable", proposed_bases: evidence["bases"], verified_rules: rules,
            residual_cents: residuals, source_digest: evidence["source_digest"],
            stored_taxes: row.attributes.slice("social_security_tax", "medicare_tax", "employee_tax_breakdown", "employer_tax_breakdown") }
        end
      rescue ArgumentError, KeyError, TypeError => error
        { historical_paycheck_id: row.id, status: "held", reason: error.message }
      end
      report.merge(source_digest: FicaBasisEvidence.digest(ImportedPaycheckFicaEvidence.source(row)),
        existing_proof_digest: FicaBasisEvidence.digest(row.fica_basis_proof&.evidence))
    end
    begin
      raise ArgumentError, "Unmapped imported paycheck" unless employee_id
      employee = company.employees.find(employee_id)
      probe = PayrollItem.new(employee: employee, company: company, employment_type: "hourly", gross_pay: 0,
        reported_tips: 0, cash_tips_reported: 0, pay_period: PayPeriod.new(pay_date: Date.new(year, 1, 1)))
      capacity = BelowThresholdFicaContext.new(employee: employee, company: company, year: year)
        .snapshot(current_item: probe, rules: rules, reviewing_imports: true)
      proofs.each_value { |evidence| evidence["annual_source_digest"] = capacity.fetch("source_digest") }
      reports.each do |report|
        report[:evidence_digest] = FicaBasisEvidence.digest(proofs.fetch(report[:historical_paycheck_id])) if report[:status] == "recoverable"
      end
      reason = nil
    rescue ArgumentError, ActiveRecord::RecordNotFound => error
      reason = error.message
      reports.each do |report|
        next unless report[:status] == "recoverable"
        report.merge!(status: "held", reason: reason)
      end
      proofs = {}
    end
    # Totals cover every individually corroborated check, including any later
    # held only by annual capacity, so reviewers see all accepted rounding.
    residuals = reports.filter_map { |row| row[:residual_cents] }
    { employee_id: employee_id, status: reason || reports.any? { |row| row[:status] == "held" } ? "held" : "ready",
      reason: reason, rows: reports, proofs: proofs, conservative_history_bounds: capacity&.fetch("bounds"),
      residual_totals_cents: ImportedPaycheckFicaEvidence.residual_totals(residuals),
      checks_with_residual: residuals.count { |entry| entry.values.any?(&:nonzero?) },
      annual_source_digest: capacity&.fetch("source_digest"),
      history_review_open: true, filing_review_open: true }
  end
end
