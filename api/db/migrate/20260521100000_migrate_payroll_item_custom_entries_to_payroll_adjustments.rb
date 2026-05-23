# frozen_string_literal: true

class MigratePayrollItemCustomEntriesToPayrollAdjustments < ActiveRecord::Migration[8.1]
  class PayrollItem < ActiveRecord::Base
    self.table_name = "payroll_items"
  end

  def up
    PayrollItem.reset_column_information

    PayrollItem.find_each do |item|
      migrated_adjustments = normalize_existing_adjustments(item.payroll_adjustments)
      migrated_adjustments += normalize_legacy_entries(item.custom_earnings, "taxable_addition")
      migrated_adjustments += normalize_legacy_entries(item.custom_deductions, "post_tax_deduction")

      next if migrated_adjustments == normalize_existing_adjustments(item.payroll_adjustments) && legacy_entries_blank?(item)

      item.update_columns(
        payroll_adjustments: migrated_adjustments,
        custom_earnings: [],
        custom_deductions: []
      )
    end
  end

  def down
    # Intentionally irreversible: payroll adjustments preserve the same payroll math
    # with explicit treatment metadata, but converting them back would lose treatment
    # distinctions for non-taxable and pre-tax entries.
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def legacy_entries_blank?(item)
    Array(item.custom_earnings).blank? && Array(item.custom_deductions).blank?
  end

  def normalize_existing_adjustments(entries)
    Array(entries).filter_map do |entry|
      data = entry.respond_to?(:to_h) ? entry.to_h : {}
      label = data["label"].to_s.strip
      amount = BigDecimal(data["amount"].to_s)
      treatment = data["treatment"].to_s
      next if label.blank? || amount <= 0 || !amount.finite?
      next unless %w[taxable_addition non_taxable_addition pre_tax_deduction post_tax_deduction].include?(treatment)

      {
        "label" => label,
        "amount" => amount.round(2).to_f,
        "treatment" => treatment,
        "notes" => data["notes"].to_s,
        "active" => data.key?("active") ? ActiveModel::Type::Boolean.new.cast(data["active"]) : true
      }
    rescue ArgumentError, FloatDomainError
      nil
    end
  end

  def normalize_legacy_entries(entries, treatment)
    Array(entries).filter_map do |entry|
      data = entry.respond_to?(:to_h) ? entry.to_h : {}
      label = data["label"].to_s.strip
      amount = BigDecimal(data["amount"].to_s)
      next if label.blank? || amount <= 0 || !amount.finite?

      {
        "label" => label,
        "amount" => amount.round(2).to_f,
        "treatment" => treatment,
        "notes" => "Migrated from legacy payroll item entry",
        "active" => true
      }
    rescue ArgumentError, FloatDomainError
      nil
    end
  end
end
