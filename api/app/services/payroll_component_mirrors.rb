# frozen_string_literal: true

# Resolve the complete saved item at once: one field can own only its generated
# deduction, and frozen independent assignments can never become mirrors.
class PayrollComponentMirrors
  class AmbiguousHistoryError < ArgumentError; end

  IDENTITY_KEY = "deduction_mirror".freeze
  TREATMENTS = { "pre_tax" => "pre_tax_deduction", "post_tax" => "post_tax_deduction",
    "employer_contribution" => "employer_contribution" }.freeze

  def self.record!(entry, deduction)
    entry.metadata = entry.metadata.to_h.deep_dup.merge(IDENTITY_KEY => {
      "version" => 1, "deduction_type_id" => deduction.deduction_type_id,
      "payroll_field_definition_id" => entry.payroll_field_definition_id
    })
  end

  def self.field_for(item, deduction)
    resolution(item)[deduction.deduction_type_id]
  end

  def self.deduction_for(item, entry)
    type_id = resolution(item).find { |_id, field| field == entry }&.first
    item.payroll_item_deductions.find { |row| row.deduction_type_id == type_id } if type_id
  end

  def self.independent_type_ids(item)
    Array(item.calculation_context_snapshot.to_h["employee_deductions"]).filter_map do |row|
      row.to_h.dig("deduction_type", "id")&.to_i
    end.to_set
  end

  def self.resolution(item, for_reporting: false)
    result = {}
    independent = independent_type_ids(item)
    rows = item.payroll_item_deductions.to_a
    item.payroll_item_field_entries.each do |entry|
      next unless entry.active? && entry.amount.to_d.nonzero? && TREATMENTS.value?(entry.tax_treatment)

      identity = entry.metadata.to_h[IDENTITY_KEY]
      candidates = rows.select { |row| matching?(entry, row) }
      if identity
        unless identity["version"] == 1 && identity["payroll_field_definition_id"] == entry.payroll_field_definition_id &&
            identity["deduction_type_id"].present? && !independent.include?(identity["deduction_type_id"].to_i)
          ambiguous!
        end
        candidates.select! { |row| row.deduction_type_id == identity["deduction_type_id"].to_i }
        ambiguous! unless candidates.one? && candidates.first.deduction_type&.company_id == item.company_id
      else
        candidates.reject! { |row| independent.include?(row.deduction_type_id) }
        next if candidates.empty?
        ambiguous! unless candidates.one? && (historical_identity?(item, entry, candidates.first) ||
          (for_reporting && PayrollReportComponentReview.compatible_mirror?(item, entry, candidates.first)))
      end
      deduction = candidates.first
      ambiguous! if result.key?(deduction.deduction_type_id)
      result[deduction.deduction_type_id] = entry
    end
    result.freeze
  end

  def self.matching?(entry, deduction)
    identified = entry.metadata.to_h.dig(IDENTITY_KEY, "deduction_type_id") == deduction.deduction_type_id
    return false unless deduction.employer_contribution? || identified || deduction.deduction_type&.name.to_s.match?(/\APayroll Field(?:\s|:)/)

    entry.tax_treatment == TREATMENTS[deduction.category] && entry.label == deduction.label &&
      (!deduction.employer_contribution? || entry.amount.to_d.round(2) == deduction.amount.to_d.round(2)) &&
      PayrollReportingGroups.normalize(entry.reporting_group) == PayrollReportingGroups.normalize(deduction.reporting_group)
  end
  private_class_method :matching?

  def self.historical_identity?(item, entry, deduction)
    return false unless deduction.deduction_type&.company_id == item.company_id
    return true if !deduction.employer_contribution? && deduction.deduction_type&.name.to_s.match?(/\APayroll Field(?:\s|:)/)

    # An old field-assignment snapshot proves the field, not which employer
    # deduction it generated. A lone matching row may be an independent source.
    PayrollLegacyEmployerComponents.field_mirror?(item, entry, deduction)
  end
  private_class_method :historical_identity?

  def self.ambiguous!
    raise AmbiguousHistoryError, "Saved payroll field mirror identity is ambiguous; arrange a reviewed component reconciliation before posting or issuing a correction"
  end
  private_class_method :ambiguous!
end
