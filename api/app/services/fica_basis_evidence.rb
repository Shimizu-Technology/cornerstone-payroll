# frozen_string_literal: true

# Stable financial source digests, shared by the reviewed recovery and runtime.
module FicaBasisEvidence
  BASE_FIELDS = %w[social_security_taxable_wages social_security_taxable_tips medicare_taxable_wages additional_medicare_taxable_wages].freeze
  RULE_FIELDS = %w[social_security_wage_base social_security_rate medicare_rate additional_medicare_rate additional_medicare_threshold].freeze

  def self.normalize(value)
    case value
    when BigDecimal then value.to_s("F")
    when Hash then value.sort.to_h.transform_values { |entry| normalize(entry) }
    when Array then value.map { |entry| normalize(entry) }
    else value
    end
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(JSON.generate(normalize(value)))
  end

  def self.row_digest(row)
    fields = EmployeeYearFicaContext::FINGERPRINT_FIELDS + %w[company_id employee_id]
    digest([ fields.map { |field| [ field, row.public_send(field) ] }, rule_evidence(row) ])
  end

  def self.rule_evidence(row)
    source = row.has_attribute?(:recorded_fica_rules) ? row[:recorded_fica_rules] : row.tax_rule_snapshot
    source.is_a?(Hash) ? source.slice("tax_year", *RULE_FIELDS).compact : {}
  end

  def self.ledger_digest(rows)
    digest(rows.sort_by(&:id).map { |row| [ row.id, row_digest(row) ] })
  end

  def self.opening_digest(opening)
    digest(opening&.attributes&.slice(*EmployeeYearFicaContext::OPENING_FIELDS))
  end

  def self.amount(value)
    number = BigDecimal(value.to_s)
    raise ArgumentError, "Non-finite evidence" unless number.finite?
    number
  end

  def self.components(bases, rules)
    ss = ((bases.fetch(:social_security_taxable_wages) + bases.fetch(:social_security_taxable_tips)) * amount(rules.fetch("social_security_rate"))).round(2, BigDecimal::ROUND_HALF_UP)
    medicare = (bases.fetch(:medicare_taxable_wages) * amount(rules.fetch("medicare_rate"))).round(2, BigDecimal::ROUND_HALF_UP)
    additional = (bases.fetch(:additional_medicare_taxable_wages) * amount(rules.fetch("additional_medicare_rate"))).round(2, BigDecimal::ROUND_HALF_UP)
    bases.merge(social_security_tax: ss, employer_social_security_tax: ss, employer_medicare_tax: medicare,
      medicare_tax: medicare + additional, additional_medicare_tax: additional)
  end

  def self.matches_recorded?(row, components)
    BASE_FIELDS.all? { |field| row.public_send(field).nil? || row.public_send(field) == components.fetch(field.to_sym) } &&
      %w[social_security_tax employer_social_security_tax medicare_tax employer_medicare_tax].all? do |field|
        row.public_send(field).present? && row.public_send(field) == components.fetch(field.to_sym)
      end && (row.additional_medicare_tax.nil? || row.additional_medicare_tax == components.fetch(:additional_medicare_tax))
  end

  def self.verified_bases(proof, row:, year:, employee_id:)
    return unless proof.is_a?(Hash) && proof["version"] == 1 && proof["year"] == year && proof["employee_id"] == employee_id
    # Apply reviewed the complete dependency digest under financial locks.
    # This append-only attestation establishes this row's bases. Later signed
    # changes/retirements/reversals of other checks must not erase that proof.
    return unless proof["row_digest"] == row_digest(row)
    through = proof.fetch("dependency_through_id")
    return unless through.is_a?(Integer) && through >= row.id
    return unless proof["dependency_count"].is_a?(Integer) && proof["dependency_count"].positive?
    return unless proof["dependency_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) && proof["opening_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
    bases = BASE_FIELDS.to_h { |field| [ field.to_sym, amount(proof.fetch("bases").fetch(field)) ] }
    return if bases.values.any?(&:negative?) || row.correction_for_payroll_item_id.present? || row.gross_pay.negative?
    return if bases[:social_security_taxable_wages] + bases[:social_security_taxable_tips] > bases[:medicare_taxable_wages]
    return if bases[:additional_medicare_taxable_wages] > bases[:medicare_taxable_wages]
    return unless bases[:medicare_taxable_wages] == (row.medicare_taxable_wages || row.gross_pay)
    return unless bases[:social_security_taxable_tips] <= (row.cash_tips_reported || row.reported_tips).to_d
    components = components(bases, proof.fetch("rules"))
    components if matches_recorded?(row, components)
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    nil
  end
end
