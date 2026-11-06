# frozen_string_literal: true

# A correction uses the original frozen profile. Older corrective snapshots
# retain that profile but may omit its election identity. Describe inherited
# evidence explicitly; never repair history or query today's election.
class PayrollItemW4Provenance
  PROFILE_KEYS = %w[
    form_version effective_on signed_on source_reference filing_status_entered
    step2_multiple_jobs step3_dependent_credit step4a_other_income step4b_deductions
    step4c_configured_extra_withholding legacy_allowances
  ].freeze

  def self.call(item)
    return unless item.correction_entry?

    current = item.tax_rule_snapshot.to_h["w4"]
    return unless current.is_a?(Hash)
    return if current["election_id"].present? && current["election_source"].present?

    original = item.correction_for_payroll_item
    return unless original && original.company_id == item.company_id && original.employee_id == item.employee_id &&
      original.pay_period.committed? && item.pay_period.corrects_pay_period_id == original.pay_period_id

    frozen = original.tax_rule_snapshot.to_h["w4"]
    return unless frozen.is_a?(Hash) && frozen["election_id"].is_a?(Integer) && frozen["election_id"].positive? &&
      frozen["election_source"].is_a?(String) && frozen["election_source"].present?
    return unless PROFILE_KEYS.all? { |key| current.key?(key) && frozen.key?(key) && current[key] == frozen[key] }
    return if current["election_id"].present? && current["election_id"] != frozen["election_id"]
    return if current["election_source"].present? && current["election_source"] != frozen["election_source"]

    { origin: "original_payroll_snapshot", original_payroll_item_id: original.id,
      original_pay_period_id: original.pay_period_id, election_id: frozen["election_id"],
      election_source: frozen["election_source"] }
  end
end
