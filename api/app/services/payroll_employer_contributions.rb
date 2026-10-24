# frozen_string_literal: true

# Expected obligations come from authoritative saved sources, independently of
# the report's display/suppression logic. Preserve source keys as well as money.
class PayrollEmployerContributions
  def self.sources(item)
    sources = {}
    %w[employer_retirement_match employer_roth_retirement_match].each do |field|
      amount = item.public_send(field).to_d.round(2)
      sources[field] = amount if amount.nonzero?
    end
    fields = item.payroll_item_field_entries.select { |entry| entry.active? && entry.employer_contribution? }
    fields.each do |entry|
      sources["payroll_field:#{entry.payroll_field_definition_id || 'snapshot'}:#{entry.id || "unsaved:#{entry.object_id}"}"] = entry.amount.to_d.round(2) if entry.amount.to_d.nonzero?
    end
    mirror_ids = PayrollComponentMirrors.resolution(item).keys.to_set
    independent = PayrollComponentMirrors.independent_type_ids(item)
    item.payroll_item_deductions.each do |row|
      next unless row.employer_contribution? && row.amount.to_d.nonzero?
      # A saved independent assignment is authoritative even if report logic
      # were to mistake its label/value for a built-in or field mirror.
      unless independent.include?(row.deduction_type_id)
        next if mirror_ids.include?(row.deduction_type_id)
        if PayrollRetirementTotals.built_in_employer_match_deduction?(item, row)
          identity = item.calculation_context_snapshot.to_h["built_in_employer_match_mirrors"].to_h
          field = PayrollRetirementTotals::BUILT_IN_EMPLOYER_MATCHES.fetch(row.label).first.to_s
          unless identity["version"] == 1 && identity.to_h.fetch("sources", {})[field] == row.deduction_type_id
            raise PayrollComponentMirrors::AmbiguousHistoryError, "Saved built-in employer match identity is ambiguous; arrange a reviewed component reconciliation before posting or issuing a correction"
          end
          next
        end
      end
      sources["deduction_type:#{row.deduction_type_id}:#{row.id || "unsaved:#{row.object_id}"}"] = row.amount.to_d.round(2)
    end
    sources
  end

  def self.total(item)
    sources(item).values.sum(0.to_d)
  end
end
