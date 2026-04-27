# frozen_string_literal: true

class EmployeeWageRateSyncService
  def self.normalize_payload(wage_rates)
    new(employee: Employee.new, wage_rates: wage_rates).send(:normalize_rates)
  end

  def initialize(employee:, wage_rates:)
    @employee = employee
    @wage_rates = Array(wage_rates)
  end

  def sync!
    normalized = normalize_rates

    existing_by_id = employee.employee_wage_rates.index_by(&:id)
    incoming_ids = normalized.filter_map { |rate| rate[:id] }

    employee.employee_wage_rates.where.not(id: incoming_ids).destroy_all if existing_by_id.any?

    normalized.each do |rate_attrs|
      rate_id = rate_attrs.delete(:id)
      if rate_id.present? && existing_by_id[rate_id]
        existing_by_id[rate_id].update!(rate_attrs)
      else
        employee.employee_wage_rates.create!(rate_attrs)
      end
    end

    normalized
  end

  private

  attr_reader :employee, :wage_rates

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
