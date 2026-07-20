# frozen_string_literal: true

# Builds historical report disclosures exclusively from snapshotted payroll
# item field entries. Current field definitions and employee defaults are never
# consulted, so renamed or retired fields cannot rewrite prior payroll reports.
class PayrollFieldDisclosure
  TREATMENTS = %w[
    taxable_addition
    non_taxable_addition
    pre_tax_deduction
    post_tax_deduction
    employer_contribution
  ].freeze

  attr_reader :items

  def initialize(items)
    @items = Array(items)
  end

  def rows
    @rows ||= items.flat_map do |item|
      item.payroll_item_field_entries.select(&:active?).map do |entry|
        {
          payroll_item_id: item.id,
          pay_period_id: item.pay_period_id,
          pay_date: item.pay_period&.pay_date,
          period_description: item.pay_period&.period_description,
          employee_id: item.employee_id,
          employee_name: item.employee&.full_name,
          employment_type: item.employment_type,
          payroll_field_definition_id: entry.payroll_field_definition_id,
          label: entry.label,
          kind: entry.kind,
          tax_treatment: entry.tax_treatment,
          category: entry.category,
          reporting_group: entry.reporting_group,
          source: entry.source,
          employee_paid: entry.employee_paid,
          employer_paid: entry.employer_paid,
          amount: entry.amount.to_f
        }
      end
    end.sort_by do |row|
      [ row[:pay_date] || Date.new(1900, 1, 1), row[:employee_name].to_s.downcase, row[:label].to_s.downcase, row[:payroll_item_id].to_i ]
    end
  end

  def totals
    rows.group_by do |row|
      [
        row[:label], row[:kind], row[:tax_treatment], row[:category],
        row[:reporting_group], row[:employee_paid], row[:employer_paid]
      ]
    end.map do |key, grouped|
      label, kind, treatment, category, reporting_group, employee_paid, employer_paid = key
      {
        label: label,
        kind: kind,
        tax_treatment: treatment,
        category: category,
        reporting_group: reporting_group,
        employee_paid: employee_paid,
        employer_paid: employer_paid,
        amount: grouped.sum { |row| row[:amount].to_f },
        employee_count: grouped.map { |row| row[:employee_id] }.compact.uniq.length,
        pay_period_count: grouped.map { |row| row[:pay_period_id] }.compact.uniq.length
      }
    end.sort_by { |row| [ treatment_rank(row[:tax_treatment]), row[:label].to_s.downcase ] }
  end

  def treatment_totals
    TREATMENTS.index_with do |treatment|
      rows.select { |row| row[:tax_treatment] == treatment }.sum { |row| row[:amount].to_f }
    end
  end

  private

  def treatment_rank(treatment)
    TREATMENTS.index(treatment) || TREATMENTS.length
  end
end
