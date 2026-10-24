# frozen_string_literal: true

# A label alone is not a mirror identity: a flexible deduction may share a
# name with a different field. Reconcile the saved treatment, group and amount.
class PayrollComponentMirrors
  def self.field_for(item, deduction)
    treatment = { "pre_tax" => "pre_tax_deduction", "post_tax" => "post_tax_deduction",
      "employer_contribution" => "employer_contribution" }[deduction.category]
    return unless deduction.employer_contribution? || deduction.deduction_type&.name.to_s.match?(/\APayroll Field(?:\s|:)/)

    # Employee field mirrors can retain the uncapped requested amount while
    # the authoritative field stores the capped amount. Their generated type
    # carries the mirror identity; employer mirrors still require equal money.
    matches = item.payroll_item_field_entries.select do |entry|
      entry.active? && entry.tax_treatment == treatment && entry.label == deduction.label &&
        (!deduction.employer_contribution? || entry.amount.to_d.round(2) == deduction.amount.to_d.round(2)) &&
        PayrollReportingGroups.normalize(entry.reporting_group) == PayrollReportingGroups.normalize(deduction.reporting_group)
    end
    matches.sole if matches.one?
  end
end
