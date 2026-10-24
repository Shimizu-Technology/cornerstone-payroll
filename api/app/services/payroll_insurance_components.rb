# frozen_string_literal: true

# Fields own their insurance liability. The compatibility scalar owns only
# non-field insurance; older capped calculations could fold in field mirrors.
class PayrollInsuranceComponents
  class AmbiguousHistoryError < ArgumentError; end

  def self.scalar_amount(item)
    rows = item.payroll_item_deductions.select { |row| row.deduction_type&.sub_category == "insurance" }
    mirrors, direct = rows.partition { |row| PayrollComponentMirrors.field_for(item, row) }
    employer_rows = direct.select(&:employer_contribution?)
    direct = direct.reject(&:employer_contribution?)
    mirrors = mirrors.reject(&:employer_contribution?)

    scalar = item.insurance_payment.to_d.round(2)
    direct_amount = direct.sum(0.to_d) { |row| row.amount.to_d }.round(2)
    mirror_amount = mirrors.sum(0.to_d) { |row| row.amount.to_d }.round(2)
    if rows.any?
      unless [ direct_amount, direct_amount + mirror_amount ].include?(scalar)
        if PayrollLegacyEmployerComponents.eligible?(item)
          old_aggregate = rows.sum(0.to_d) { |row| row.amount.to_d }.round(2)
          return direct_amount if scalar == old_aggregate
        end
        if employer_rows.any?
          raise AmbiguousHistoryError, "Employer insurance aggregate provenance requires a reviewed benefit-ledger correction"
        end
        raise AmbiguousHistoryError, "Insurance aggregate provenance is ambiguous; review the insurance ledger before correcting this paycheck"
      end
      direct_amount
    elsif field_amount(item).nonzero? && scalar.nonzero?
      raise AmbiguousHistoryError, "Insurance field and legacy aggregate provenance is ambiguous; review the insurance ledger before correcting this paycheck"
    else
      scalar
    end
  end

  def self.field_amount(item)
    item.payroll_item_field_entries.sum(0.to_d) do |row|
      row.active? && row.kind == "deduction" && row.category == "insurance" ? row.amount.to_d : 0.to_d
    end.round(2)
  end

  def self.total(item)
    scalar_amount(item) + field_amount(item)
  end

  def self.verify_postings!(item)
    entries = PayrollLiabilityEntry.where(payroll_item_id: item.id, category: "insurance_employee")
    return unless item.pay_period.payroll_liability_postings.exists?
    return if entries.sum(:amount).to_d.round(2) == total(item)
    if PayrollLegacyEmployerComponents.eligible?(item)
      return if entries.sum(:amount).to_d.round(2) == item.insurance_payment.to_d + field_amount(item)
    end

    raise AmbiguousHistoryError, "Saved insurance liability entries do not reconcile with the insurance components; arrange a reviewed insurance-ledger correction"
  end
end
