# frozen_string_literal: true

class ClientEmployeeUpdateService
  WAGE_RATES_KEY = :wage_rates

  Result = Struct.new(:employee, :applied_direct_fields, :changed_fields, :before_values, :after_values, keyword_init: true)

  def initialize(employee:, attrs:, requested_by:, company:)
    @employee = employee
    @attrs = normalize_attrs(attrs.deep_symbolize_keys)
    @requested_by = requested_by
    @company = company
  end

  def create!
    ActiveRecord::Base.transaction do
      employee.assign_attributes(attrs.except(WAGE_RATES_KEY))
      employee.company = company
      employee.save!
      sync_wage_rates!(attrs[WAGE_RATES_KEY]) if attrs[WAGE_RATES_KEY].present?

      created_fields = attrs.keys
      Result.new(
        employee: employee.reload,
        applied_direct_fields: created_fields,
        changed_fields: created_fields,
        before_values: {},
        after_values: serialized_values_for(created_fields)
      )
    end
  end

  def update!
    changed_fields = []
    before_values = {}
    after_values = {}

    ActiveRecord::Base.transaction do
      changed_attrs = changed_attributes_subset(attrs.except(WAGE_RATES_KEY))
      if changed_attrs.present?
        before_values.merge!(serialize_payload(original_values_for(changed_attrs.keys)))
        employee.update!(changed_attrs)
        changed_fields.concat(changed_attrs.keys)
      end

      if attrs.key?(WAGE_RATES_KEY)
        normalized_wage_rates = normalized_wage_rates_payload(attrs[WAGE_RATES_KEY])
        if wage_rates_changed?(normalized_wage_rates)
          before_values[WAGE_RATES_KEY] = serialize_payload(current_wage_rates_payload)
          sync_wage_rates!(attrs[WAGE_RATES_KEY])
          changed_fields << WAGE_RATES_KEY
        end
      end

      after_values = serialized_values_for(changed_fields)
    end

    Result.new(
      employee: employee.reload,
      applied_direct_fields: changed_fields,
      changed_fields: changed_fields,
      before_values: before_values,
      after_values: after_values
    )
  end

  private

  attr_reader :employee, :attrs, :requested_by, :company

  def changed_attributes_subset(subset)
    subset.each_with_object({}) do |(key, value), acc|
      next unless attribute_changed?(key, value)

      acc[key] = value
    end
  end

  def attribute_changed?(key, value)
    current = employee.public_send(key)
    normalize_compare_value(current) != normalize_compare_value(value)
  end

  def normalize_compare_value(value)
    case value
    when BigDecimal
      value.to_f.round(4)
    when Numeric
      value.to_f.round(4)
    when TrueClass, FalseClass
      value
    when Date, Time, DateTime
      value.to_s
    else
      value.presence
    end
  end

  def original_values_for(keys)
    keys.each_with_object({}) do |key, acc|
      acc[key] =
        if key == WAGE_RATES_KEY
          current_wage_rates_payload
        else
          employee.public_send(key)
        end
    end
  end

  def normalized_wage_rates_payload(raw_rates)
    EmployeeWageRateSyncService.normalize_payload(raw_rates).map do |rate|
      rate.except(:id)
    end
  end

  def current_wage_rates_payload
    employee.active_wage_rates.map do |rate|
      {
        label: rate.label,
        rate: rate.rate.to_f,
        is_primary: rate.is_primary,
        active: rate.active
      }
    end
  end

  def wage_rates_changed?(normalized_wage_rates)
    current_wage_rates_payload != normalized_wage_rates.map do |rate|
      {
        label: rate[:label],
        rate: rate[:rate].to_f,
        is_primary: rate[:is_primary],
        active: rate[:active]
      }
    end
  end

  def sync_wage_rates!(rates)
    EmployeeWageRateSyncService.new(employee: employee, wage_rates: rates, replace_missing: true).sync!
  end

  def normalize_attrs(raw_attrs)
    raw_attrs.each_with_object({}) do |(key, value), acc|
      acc[key] =
        if key == WAGE_RATES_KEY
          value
        else
          cast_attribute_value(key, value)
        end
    end
  end

  def cast_attribute_value(key, value)
    type = employee.class.attribute_types[key.to_s]
    return value unless type

    type.cast(value)
  end

  def serialize_payload(value)
    case value
    when Hash
      value.transform_values { |nested| serialize_payload(nested) }
    when Array
      value.map { |nested| serialize_payload(nested) }
    when BigDecimal
      value.to_f
    else
      value
    end
  end

  def serialized_values_for(keys)
    original_values_for(keys).transform_values { |value| serialize_payload(value) }
  end
end
