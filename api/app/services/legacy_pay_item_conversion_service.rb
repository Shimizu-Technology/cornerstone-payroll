# frozen_string_literal: true

# Replaces one active legacy recurring item with an employee-owned typed field
# in one transaction. There is never a saved state in which both schedules
# apply, and historical payroll snapshots are left untouched.
class LegacyPayItemConversionService
  class SourceChanged < StandardError; end
  class InvalidSource < StandardError; end
  class UnsafeOpenPayroll < StandardError; end

  def initialize(employee:, actor:, source:, field_attributes:, assignment_attributes:)
    @employee = employee
    @actor = actor
    @source = source.to_h.deep_symbolize_keys
    @field_attributes = field_attributes.to_h.deep_symbolize_keys
    @assignment_attributes = assignment_attributes.to_h.deep_symbolize_keys
  end

  def call
    Employee.transaction do
      employee.lock!
      entries, index, legacy_item = find_source!
      @first_payday = parse_assignment_date!(:start_date)
      @last_payday = parse_assignment_date!(:end_date)
      ensure_open_payroll_can_refresh!(legacy_item)
      treatment = source_kind == "custom_earning" ? "taxable_addition" : legacy_item.fetch("treatment")
      kind = treatment.end_with?("_addition") ? "addition" : "deduction"
      amount = legacy_item.fetch("amount")

      unless PayrollFieldDefinition::CATEGORIES.include?(field_attributes[:category].to_s)
        raise InvalidSource, "Choose a category for the new pay item"
      end

      metadata = field_attributes.slice(
        :name, :description, :category, :reporting_group, :payee_name, :reference_number
      )
      metadata[:reporting_group] = nil unless metadata[:category].to_s == "retirement"
      field = PayrollFieldDefinition.create!(metadata.merge(
        company: employee.company, owner_employee: employee,
        kind: kind, tax_treatment: treatment, amount_type: "fixed",
        default_amount: amount, show_in_payroll_grid: true
      ))
      assignment = employee.employee_payroll_fields.create!(
        assignment_attributes.slice(:start_date, :end_date, :notes).merge(
          payroll_field_definition: field, amount: amount, active: true
        )
      )

      entries.delete_at(index)
      if source_kind == "custom_earning"
        employee.update!(default_custom_earnings: entries)
      else
        employee.update!(default_payroll_adjustments: entries)
      end

      AuditLog.record!(
        user: actor, company_id: employee.company_id,
        action: "employee_payroll_fields#convert_legacy", record_type: "employees",
        record_id: employee.id, subject_name: employee.full_name,
        metadata: { source_kind: source_kind, source_label: legacy_item.fetch("label"),
                    amount: amount, treatment: treatment, payroll_field_definition_id: field.id }
      )
      [ field, assignment ]
    end
  end

  private

  attr_reader :employee, :actor, :source, :field_attributes, :assignment_attributes

  def source_kind
    source[:kind].to_s
  end

  def find_source!
    entries = case source_kind
    when "adjustment"
      Employee.normalize_payroll_adjustments(employee.default_payroll_adjustments)
    when "custom_earning"
      PayrollItem.normalize_custom_earning_entries(employee.default_custom_earnings)
    else
      raise InvalidSource, "Choose a legacy earning or adjustment"
    end

    index = entries.index { |entry| source_matches?(entry) }
    raise SourceChanged, "This legacy item changed. Reload the employee before moving it." unless index

    [ entries, index, entries.fetch(index) ]
  end

  def source_matches?(entry)
    return false if source_kind == "adjustment" && entry["active"] == false
    return false unless entry["label"] == source[:label].to_s.strip
    return false unless BigDecimal(entry["amount"].to_s).round(2) == BigDecimal(source[:amount].to_s).round(2)
    return true if source_kind == "custom_earning"

    entry["treatment"] == source[:treatment].to_s &&
      entry.fetch("notes", "") == source[:notes].to_s.strip
  rescue ArgumentError
    false
  end

  # A manually edited or untracked payroll-item snapshot will not necessarily
  # refresh from employee defaults on recalculation. If it still contains this
  # legacy row, adding the typed field for the same payday would double count.
  def ensure_open_payroll_can_refresh!(legacy_item)
    employee.payroll_items.joins(:pay_period)
      .where(pay_periods: { status: %w[draft calculated approved] })
      .includes(:pay_period).find_each do |item|
      period = item.pay_period
      next unless period.recurring_items_enabled?
      next unless assignment_applies_on?(period.pay_date)

      rows = if source_kind == "custom_earning"
        PayrollItem.normalize_custom_earning_entries(item.custom_earnings)
      else
        PayrollItem.normalize_payroll_adjustments(item.payroll_adjustments)
      end
      # Manual payroll edits can change the amount or note while retaining the
      # same item. Match its identity here, not the exact employee default.
      next unless rows.any? { |row| snapshot_contains_source?(row) }

      refreshes_defaults = if source_kind == "custom_earning"
        data = item.custom_columns_data.is_a?(Hash) ? item.custom_columns_data : {}
        !item.custom_earnings_overridden? && data[PayrollItem::CUSTOM_EARNINGS_SOURCE_KEY] == PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE
      else
        !item.payroll_adjustments_overridden? && item.payroll_adjustments_default_snapshot?
      end
      next if refreshes_defaults

      raise UnsafeOpenPayroll, "Pay period #{period.id} has an edited or untracked copy of this item. Set the new item's first payday after #{period.pay_date}, or resolve that payroll item's override before moving it."
    end
  end

  def snapshot_contains_source?(row)
    return false unless row["label"] == legacy_source_label
    return true if source_kind == "custom_earning"

    row["treatment"] == source[:treatment].to_s
  end

  def legacy_source_label
    source[:label].to_s.strip
  end

  def assignment_applies_on?(pay_date)
    (@first_payday.nil? || @first_payday <= pay_date) && (@last_payday.nil? || pay_date <= @last_payday)
  end

  def parse_assignment_date!(key)
    value = assignment_attributes[key]
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise InvalidSource, "Enter a valid #{key == :start_date ? 'first' : 'last'} payday"
  end
end
