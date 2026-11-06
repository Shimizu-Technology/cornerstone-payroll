# frozen_string_literal: true

# Never invert rounded tax. Only the full, ordinary gross/tip allocation is
# supported; the caller must additionally establish the complete annual bound.
# Bases always come from imported gross/tip amounts. Stored taxes only
# corroborate them: QuickBooks rounds each check independently, so each present
# tax component may differ from the rule-computed amount by at most one cent.
# Every signed residual is retained in the plan and proof evidence.
module ImportedPaycheckFicaEvidence
  VERSION = 2
  SS = /\A(?:SS|Social Security(?: Employer)?)\z/i
  MEDICARE = /\A(?:Med|Medicare(?: Employer)?)\z/i
  TOLERANCE = BigDecimal("0.01")
  TOLERANCE_CENTS = 1
  RESIDUAL_COMPONENTS = %w[employee_social_security_tax employee_medicare_tax employer_social_security_tax employer_medicare_tax].freeze

  def self.source(row)
    [ row.attributes, row.historical_import_batch.attributes,
      row.historical_worker.attributes, row.historical_pay_period.attributes,
      row.historical_paycheck_adjustments.map(&:attributes) ]
  end

  def self.bases(row, rules)
    corroborate(row, rules).fetch(:bases)
  end

  # Returns the gross-derived bases and signed per-component residuals in
  # cents (stored minus rule-computed) for every present tax component.
  def self.corroborate(row, rules)
    errors = []
    errors << "import batch is not locked" unless row.historical_import_batch.locked?
    errors << "employee mapping is absent or inconsistent" unless row.employee_id &&
      row.employee&.company_id == row.company_id && row.historical_worker.employee_id == row.employee_id
    errors << "unsupported imported source status" unless %w[recorded paid].include?(row.source_status)
    errors << "unreviewed import mapping" unless %w[matched opening_summary].include?(row.reconciliation_status)
    errors << "signed historical adjustments require separate reconciliation" if row.historical_paycheck_adjustments.any?
    gross = FicaBasisEvidence.amount(row.gross_pay)
    earnings = entries(row.earnings_breakdown)
    tips = earnings.sum(0.to_d) { |label, value| label.match?(QuickbooksHistory::YtdBridgePlan::TIPS) ? value : 0.to_d }
    errors << "earnings detail does not total gross" unless earnings.sum(0.to_d, &:last) == gross
    if gross.negative? || tips.negative? || tips > gross || earnings.any? { |_, value| value.negative? }
      errors << "signed or contradictory gross/tip earnings"
    end
    if earnings.any? { |label, _| label.match?(/tip/i) && !label.match?(QuickbooksHistory::YtdBridgePlan::TIPS) }
      errors << "unsupported tip earnings label requires reviewed allocation"
    end
    if earnings.any? { |label, value| value.nonzero? && label.match?(QuickbooksHistory::YtdBridgePlan::NON_TAXABLE_EARNING) } ||
        entries(row.pretax_deduction_breakdown).any? { |label, value| value.nonzero? && label.match?(QuickbooksHistory::YtdBridgePlan::FICA_EXEMPT_PRETAX_DEDUCTION) }
      errors << "explicit FICA-exempt source components contradict full-gross recovery"
    end
    [ row.employee_tax_breakdown, row.employer_tax_breakdown ].each do |breakdown|
      if entries(breakdown).any? { |label, value| value.nonzero? && label.match?(/additional.*medicare|medicare.*additional/i) }
        errors << "stored Additional Medicare exposure requires reviewed allocation"
      end
    end
    result = { social_security_taxable_wages: gross - tips, social_security_taxable_tips: tips,
      medicare_taxable_wages: gross, additional_medicare_taxable_wages: 0.to_d }
    expected = FicaBasisEvidence.components(result, rules)
    residuals = {}
    { social_security_tax: SS, medicare_tax: MEDICARE }.each do |field, pattern|
      stored = FicaBasisEvidence.amount(row.public_send(field))
      detail = entries(row.employee_tax_breakdown).select { |label, _| label.match?(pattern) }
      # Summary/detail agreement is internal source consistency, not rounding.
      errors << "employee #{field} detail contradicts recorded tax" unless detail.sum(0.to_d, &:last) == stored
      residual(errors, residuals, "employee", field, stored, expected.fetch(field))
      employer = entries(row.employer_tax_breakdown).select { |label, _| label.match?(pattern) }
      residual(errors, residuals, "employer", field, employer.sum(0.to_d, &:last), expected.fetch(:"employer_#{field}")) if employer.any?
    end
    raise ArgumentError, errors.join("; ") if errors.any?

    { bases: result, residual_cents: residuals }
  end

  def self.residual(errors, residuals, party, field, stored, computed)
    difference = stored - computed
    cents = difference * 100
    if !cents.frac.zero?
      errors << "#{party} #{field} is not a whole-cent amount (stored #{stored.to_s("F")})"
    elsif difference.abs > TOLERANCE
      errors << "#{party} #{field} differs from the rule-computed amount by #{signed(difference)} " \
        "(stored #{format("%.2f", stored)}, computed #{format("%.2f", computed)}), beyond the $0.01 per-check rounding tolerance"
    else
      residuals["#{party}_#{field}"] = cents.to_i
    end
  end

  def self.signed(amount)
    "#{amount.negative? ? "-" : "+"}$#{format("%.2f", amount.abs)}"
  end

  def self.residual_totals(residuals)
    RESIDUAL_COMPONENTS.to_h { |component| [ component, residuals.sum { |entry| entry.fetch(component, 0) } ] }
  end

  def self.entries(value)
    raise ArgumentError, "Missing imported component detail" unless value.is_a?(Array)

    value.map do |entry|
      label = entry.fetch("label")
      raise ArgumentError, "Missing imported component label" unless label.is_a?(String) && label.present?
      [ label, FicaBasisEvidence.amount(entry.fetch("amount")) ]
    end
  end

  def self.verified_bases(row, rules:, year:)
    proof = row.fica_basis_proof&.evidence
    return unless proof.is_a?(Hash) && proof["version"] == VERSION && proof["year"] == year && proof["employee_id"] == row.employee_id
    return unless proof["corroboration_tolerance_cents"] == TOLERANCE_CENTS
    return unless proof["source_digest"] == FicaBasisEvidence.digest(source(row))
    return unless proof["rule_digest"] == FicaBasisEvidence.digest(proof.fetch("rules"))
    return unless FicaBasisEvidence::RULE_FIELDS.all? do |field|
      FicaBasisEvidence.amount(proof.fetch("rules").fetch(field)) == FicaBasisEvidence.amount(rules.fetch(field))
    end
    return unless proof["annual_source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)

    result = corroborate(row, rules)
    return unless proof["residual_cents"] == result.fetch(:residual_cents)

    result.fetch(:bases) if proof["bases"] == FicaBasisEvidence.normalize(result.fetch(:bases).stringify_keys)
  rescue ArgumentError, KeyError, TypeError
    nil
  end
end
