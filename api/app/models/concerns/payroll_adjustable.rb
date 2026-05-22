# frozen_string_literal: true

module PayrollAdjustable
  extend ActiveSupport::Concern

  ADJUSTMENT_TREATMENTS = %w[
    taxable_addition
    non_taxable_addition
    pre_tax_deduction
    post_tax_deduction
    memo
  ].freeze

  TREATMENT_LABELS = {
    "taxable_addition" => "Adds taxable pay",
    "non_taxable_addition" => "Adds non-taxable reimbursement",
    "pre_tax_deduction" => "Deducts before taxes",
    "post_tax_deduction" => "Deducts after taxes",
    "memo" => "Memo only"
  }.freeze

  class_methods do
    def normalize_payroll_adjustments(entries)
      Array(entries).filter_map do |entry|
        data = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
        label = data["label"].to_s.strip
        amount = BigDecimal(data["amount"].to_s)
        treatment = data["treatment"].to_s
        notes = data["notes"].to_s.strip
        active = data.key?("active") ? ActiveModel::Type::Boolean.new.cast(data["active"]) : true

        next if label.blank? || amount <= 0 || !amount.finite? || !ADJUSTMENT_TREATMENTS.include?(treatment)

        normalized = {
          "label" => label,
          "amount" => amount.round(2).to_f,
          "treatment" => treatment,
          "active" => active
        }
        normalized["notes"] = notes if notes.present?
        normalized
      rescue ArgumentError, FloatDomainError, NoMethodError
        nil
      end
    end
  end

  def active_payroll_adjustments
    self.class.normalize_payroll_adjustments(payroll_adjustments).select { |adjustment| adjustment["active"] != false }
  end

  def payroll_adjustments_total(*treatments)
    active_payroll_adjustments.sum do |adjustment|
      treatments.include?(adjustment["treatment"]) ? adjustment["amount"].to_f : 0.0
    end
  end
end
