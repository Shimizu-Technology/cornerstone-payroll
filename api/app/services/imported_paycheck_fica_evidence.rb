# frozen_string_literal: true

# Never invert rounded tax. Only the full, ordinary gross/tip allocation is
# supported; the caller must additionally establish the complete annual bound.
module ImportedPaycheckFicaEvidence
  SS = /\A(?:SS|Social Security(?: Employer)?)\z/i
  MEDICARE = /\A(?:Med|Medicare(?: Employer)?)\z/i

  def self.source(row)
    [ row.attributes, row.historical_import_batch.attributes,
      row.historical_worker.attributes, row.historical_pay_period.attributes,
      row.historical_paycheck_adjustments.map(&:attributes) ]
  end

  def self.bases(row, rules)
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
    { social_security_tax: SS, medicare_tax: MEDICARE }.each do |field, pattern|
      value = expected.fetch(field)
      errors << "#{field} does not exactly corroborate full gross under verified year rules" unless FicaBasisEvidence.amount(row.public_send(field)) == value
      detail = entries(row.employee_tax_breakdown).select { |label, _| label.match?(pattern) }
      errors << "employee #{field} detail contradicts recorded tax" unless detail.sum(0.to_d, &:last) == FicaBasisEvidence.amount(row.public_send(field))
      employer = entries(row.employer_tax_breakdown).select { |label, _| label.match?(pattern) }
      if employer.any? && employer.sum(0.to_d, &:last) != expected.fetch(:"employer_#{field}")
        errors << "employer #{field} does not exactly corroborate full gross under verified year rules"
      end
    end
    raise ArgumentError, errors.join("; ") if errors.any?

    result
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
    return unless proof.is_a?(Hash) && proof["version"] == 1 && proof["year"] == year && proof["employee_id"] == row.employee_id
    return unless proof["source_digest"] == FicaBasisEvidence.digest(source(row))
    return unless proof["rule_digest"] == FicaBasisEvidence.digest(proof.fetch("rules"))
    return unless FicaBasisEvidence::RULE_FIELDS.all? do |field|
      FicaBasisEvidence.amount(proof.fetch("rules").fetch(field)) == FicaBasisEvidence.amount(rules.fetch(field))
    end
    return unless proof["annual_source_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)

    result = bases(row, rules)
    result if proof["bases"] == FicaBasisEvidence.normalize(result.stringify_keys)
  rescue ArgumentError, KeyError, TypeError
    nil
  end
end
