# frozen_string_literal: true

class EmployeeWageRateSyncService
  def self.normalize_payload(wage_rates)
    new(employee: Employee.new, wage_rates: wage_rates).send(:normalize_rates)
  end

  def initialize(employee:, wage_rates:, replace_missing: false)
    @employee = employee
    @wage_rates = Array(wage_rates)
    @replace_missing = replace_missing
  end

  # Applies the desired wage-rate list to the employee's wage-rate rows. Only
  # EmployeeCompensationChangeService calls this, inside its write context,
  # and then records the versions and re-syncs the rows to today's values.
  def apply_under_compensation_context!
    unless EmployeeCompensationChangeService.writing?(employee.id)
      raise EmployeeCompensationChangeService::CompensationMutationError,
            "Sync wage rates through EmployeeCompensationChangeService"
    end

    normalized = normalize_rates
    rows = employee.employee_wage_rates.reload.to_a
    existing_by_id = rows.index_by(&:id)
    incoming_ids = normalized.filter_map { |rate| rate[:id] }

    # Removed rates are ended, not deleted: their history and the payroll
    # wage-rate buckets that reference them stay intact.
    if replace_missing?
      rows.each do |row|
        row.update!(active: false, is_primary: false) if row.active? && !incoming_ids.include?(row.id)
      end
    end

    normalized.each do |rate_attrs|
      rate_attrs = rate_attrs.dup
      rate_id = rate_attrs.delete(:id)
      if rate_id.present? && existing_by_id[rate_id]
        existing_by_id[rate_id].update!(rate_attrs)
      elsif (ended = rows.find { |row| !row.active? && !incoming_ids.include?(row.id) && row.label.casecmp?(rate_attrs[:label]) })
        # Re-adding a label that was removed earlier reuses its ended row,
        # whose label is still unique for the employee.
        ended.update!(rate_attrs)
      else
        employee.employee_wage_rates.create!(rate_attrs)
      end
    end

    normalized
  end

  private

  attr_reader :employee, :wage_rates

  def replace_missing?
    @replace_missing
  end

  def normalize_rates
    cleaned = wage_rates.filter_map do |rate|
      attrs = rate.respond_to?(:to_h) ? rate.to_h.symbolize_keys : {}
      label = attrs[:label].to_s.strip
      next if label.blank?

      {
        id: attrs[:id].presence&.to_i,
        label: label,
        rate: round_currency(attrs[:rate]),
        is_primary: ActiveModel::Type::Boolean.new.cast(attrs[:is_primary]),
        active: attrs.key?(:active) ? ActiveModel::Type::Boolean.new.cast(attrs[:active]) : true
      }
    end

    primary_id = cleaned.find { |rate| rate[:is_primary] }&.dig(:id)
    primary_index = cleaned.find_index { |rate| rate[:is_primary] } || 0

    cleaned.map.with_index do |rate, index|
      rate.merge(is_primary: primary_id.present? ? rate[:id] == primary_id : index == primary_index)
    end
  end

  def round_currency(value)
    BigDecimal(value.to_s).round(2)
  end
end
