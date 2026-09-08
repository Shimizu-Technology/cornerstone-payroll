# frozen_string_literal: true

# Builds report disclosures from the adjustment snapshot stored on each payroll
# item. Employee defaults are deliberately never consulted: changing an
# employee profile must not rewrite the explanation of a completed payroll.
class PayrollAdjustmentDisclosure
  TREATMENTS = PayrollAdjustable::ADJUSTMENT_TREATMENTS.freeze
  LEGACY_SNAPSHOT_SOURCE = "legacy_snapshot"

  attr_reader :items

  def self.source_for(item)
    return PayrollItem::MANUAL_ADJUSTMENTS_SOURCE if item.payroll_adjustments_overridden?
    return PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE if item.payroll_adjustments_default_snapshot?

    LEGACY_SNAPSHOT_SOURCE
  end

  def initialize(items)
    @items = Array(items)
  end

  def rows
    @rows ||= items.flat_map do |item|
      item.active_payroll_adjustments.map.with_index do |adjustment, index|
        treatment = adjustment.fetch("treatment")
        {
          payroll_item_id: item.id,
          pay_period_id: item.pay_period_id,
          pay_date: item.pay_period&.pay_date,
          period_description: item.pay_period&.period_description,
          employee_id: item.employee_id,
          employee_name: item.employee&.full_name,
          employment_type: item.employment_type,
          position: index,
          label: adjustment.fetch("label"),
          treatment: treatment,
          kind: deduction?(treatment) ? "deduction" : "addition",
          source: self.class.source_for(item),
          employee_paid: deduction?(treatment),
          employer_paid: false,
          amount: adjustment.fetch("amount").to_f,
          notes: adjustment["notes"].presence
        }
      end
    end.sort_by do |row|
      [ row[:pay_date] || Date.new(1900, 1, 1), row[:employee_name].to_s.downcase,
        treatment_rank(row[:treatment]), row[:label].to_s.downcase, row[:position] ]
    end
  end

  def totals
    rows.group_by { |row| [ row[:label], row[:treatment], row[:source] ] }.map do |(label, treatment, source), grouped|
      {
        label: label,
        treatment: treatment,
        kind: grouped.first[:kind],
        source: source,
        employee_paid: grouped.first[:employee_paid],
        employer_paid: false,
        amount: grouped.sum { |row| row[:amount].to_f },
        employee_count: grouped.map { |row| row[:employee_id] }.compact.uniq.length,
        pay_period_count: grouped.map { |row| row[:pay_period_id] }.compact.uniq.length
      }
    end.sort_by { |row| [ treatment_rank(row[:treatment]), row[:label].to_s.downcase, row[:source] ] }
  end

  def treatment_totals
    TREATMENTS.index_with do |treatment|
      rows.select { |row| row[:treatment] == treatment }.sum { |row| row[:amount].to_f }
    end
  end

  private

  def deduction?(treatment)
    treatment.in?(%w[pre_tax_deduction post_tax_deduction])
  end

  def treatment_rank(treatment)
    TREATMENTS.index(treatment) || TREATMENTS.length
  end
end
