# frozen_string_literal: true

# Classifies a payroll row without treating zero net pay as zero activity.
# The same decision is used before a new run is finalized and when reviewing
# committed rows for a legacy presentation disposition.
class PayrollItemActivity
  REPORTABLE_FIELDS = %i[
    gross_pay net_pay non_taxable_pay reported_tips tips_paid_out service_charge_wages
    withholding_tax additional_withholding social_security_tax medicare_tax
    additional_medicare_tax employer_social_security_tax employer_medicare_tax
    employer_retirement_match employer_roth_retirement_match
    fit_taxable_wages social_security_taxable_wages social_security_taxable_tips
    medicare_taxable_wages additional_medicare_taxable_wages cash_tips_reported
    qualified_overtime_compensation
  ].freeze
  INPUT_FIELDS = %i[
    total_additions total_deductions bonus imported_bonus tips retirement_payment
    roth_retirement_payment insurance_payment loan_deduction loan_payment
    withholding_tax_adjustment withholding_tax_override additional_withholding_override
    salary_override hours_worked overtime_hours holiday_hours pto_hours
  ].freeze
  PAYMENT_FIELDS = %i[
    check_number check_date check_printed_at check_prepared_at
    replaced_check_number reprint_of_check_number voided_at
  ].freeze
  LINK_MODELS = {
    loan_transactions: [ LoanTransaction, :payroll_item_id ],
    payroll_liability_entries: [ PayrollLiabilityEntry, :payroll_item_id ],
    payroll_time_allocations: [ PayrollTimeAllocation, :payroll_item_id ],
    time_tracking_entry_allocations: [ TimeTrackingEntryAllocation, :payroll_item_id ],
    aire_payroll_entry_acknowledgements: [ AirePayrollEntryAcknowledgement, :payroll_item_id ],
    check_events: [ CheckEvent, :payroll_item_id ],
    check_reconciliation_events: [ CheckReconciliationEvent, :payroll_item_id ],
    payroll_intake_rows: [ PayrollIntakeRow, :applied_payroll_item_id ],
    timecards: [ Timecard, :applied_payroll_item_id ],
    correction_payroll_items: [ PayrollItem, :correction_for_payroll_item_id ]
  }.freeze

  def self.classify(item)
    new(item).classify
  end

  def self.reasons(item)
    new(item).reasons
  end

  # Classifies a run without issuing one linkage query per zero-valued row.
  # The returned hash is keyed by the same item objects passed by the caller.
  def self.classify_many(items)
    analyze_many(items).transform_values { |analysis| analysis.fetch(:classification) }
  end

  def self.analyze_many(items)
    items = Array(items)
    linked = linked_reasons_for(items)
    items.to_h do |item|
      inspector = new(item, linked_reasons: linked.fetch(item.id, []))
      [ item, { classification: inspector.classify, reasons: inspector.reasons } ]
    end
  end

  def self.linked_reasons_for(items)
    persisted = items.select(&:persisted?)
    ids = persisted.map(&:id)
    return {} if ids.empty?

    reasons = Hash.new { |hash, id| hash[id] = [] }
    LINK_MODELS.each do |name, (model, foreign_key)|
      model.where(foreign_key => ids).distinct.pluck(foreign_key).each do |id|
        reasons[id] << name.to_s
      end
    end
    period_ids = persisted.map(&:pay_period_id).uniq
    CheckPrintGeneration.where(pay_period_id: period_ids).pluck(:payroll_item_ids).each do |selection|
      (Array(selection).map(&:to_i) & ids).each { |id| reasons[id] << "check_print_generations" }
    end
    CheckPrintRun.where(pay_period_id: period_ids).pluck(:manifest).each do |manifest|
      Array(manifest).each do |entry|
        next unless entry["source_type"] == "payroll_item"

        id = entry["source_id"].to_i
        reasons[id] << "check_print_runs" if ids.include?(id)
      end
    end
    reasons
  end
  private_class_method :linked_reasons_for

  def initialize(item, linked_reasons: nil)
    @item = item
    @linked_reasons = linked_reasons
  end

  def classify
    return :active if active_reasons.any?
    return :review if review_reasons.any?

    :verified_empty
  end

  def reasons
    { active: active_reasons, review: review_reasons }
  end

  private

  attr_reader :item

  def active_reasons
    @active_reasons ||= begin
      reasons = REPORTABLE_FIELDS.filter_map do |field|
        field.to_s if nonzero?(item.public_send(field))
      end
      reasons << "employer_contribution_field" if item.payroll_item_field_entries.any? do |row|
        row.active? && row.tax_treatment == "employer_contribution" && nonzero?(row.amount)
      end
      reasons << "employer_contribution_deduction" if item.payroll_item_deductions.any? do |row|
        row.category == "employer_contribution" && nonzero?(row.amount)
      end
      reasons
    end
  end

  def review_reasons
    @review_reasons ||= begin
      reasons = INPUT_FIELDS.filter_map { |field| field.to_s if nonzero?(item.public_send(field)) }
      reasons << "wage_rate_hours" if Array(item.wage_rate_hours).any? do |row|
        %w[regular_hours overtime_hours holiday_hours pto_hours].any? do |key|
          numeric_nonzero?(row.to_h[key] || row.to_h[key.to_sym])
        end
      end
      reasons << "custom_earnings" if flexible_amounts(item.custom_earnings).any?(&method(:nonzero?))
      reasons << "custom_deductions" if flexible_amounts(item.custom_deductions).any?(&method(:nonzero?))
      reasons << "payroll_adjustments" if flexible_amounts(item.payroll_adjustments).any?(&method(:nonzero?))
      reasons << "payroll_item_earnings" if item.payroll_item_earnings.any? { |row| nonzero?(row.amount) || nonzero?(row.hours) }
      reasons << "payroll_item_deductions" if item.payroll_item_deductions.any? { |row| row.category != "employer_contribution" && nonzero?(row.amount) }
      reasons << "payroll_item_field_entries" if item.payroll_item_field_entries.any? { |row| row.active? && row.tax_treatment != "employer_contribution" && nonzero?(row.amount) }
      reasons << "correction_for_payroll_item_id" if item.correction_for_payroll_item_id.present?
      reasons.concat(PAYMENT_FIELDS.filter_map { |field| field.to_s if item.public_send(field).present? })
      reasons << "check_print_count" if item.check_print_count.to_i.positive?
      reasons << "voided" if item.voided?
      reasons << "import_source" if item.import_source.present?
      reasons << "period_pay_evidence" if item.custom_columns_data.to_h["period_pay_evidence"].present?
      reasons << "timekeeping_source" if item.timekeeping_source.present? && item.timekeeping_source != "schedule"
      if @linked_reasons
        reasons.concat(@linked_reasons)
      elsif item.persisted?
        LINK_MODELS.each do |name, (model, foreign_key)|
          reasons << name.to_s if model.where(foreign_key => item.id).exists?
        end
        reasons << "check_print_generations" if CheckPrintGeneration.where("payroll_item_ids @> ?::jsonb", [ item.id ].to_json).exists?
        reasons << "check_print_runs" if CheckPrintRun.where("manifest @> ?::jsonb", [ { source_type: "payroll_item", source_id: item.id } ].to_json).exists?
      end
      reasons
    end
  end

  def flexible_amounts(entries)
    Array(entries).filter_map { |entry| entry.to_h["amount"] || entry.to_h[:amount] }
  end

  def numeric_nonzero?(value)
    value.present? && !value.to_d.zero?
  end

  def nonzero?(value)
    return false if value.nil?

    !value.to_d.zero?
  end
end
