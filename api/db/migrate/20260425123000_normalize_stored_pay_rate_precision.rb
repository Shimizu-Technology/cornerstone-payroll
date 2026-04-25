# frozen_string_literal: true

class NormalizeStoredPayRatePrecision < ActiveRecord::Migration[8.0]
  class MigrationEmployee < ApplicationRecord
    self.table_name = "employees"
  end

  class MigrationEmployeeWageRate < ApplicationRecord
    self.table_name = "employee_wage_rates"
  end

  class MigrationPayPeriod < ApplicationRecord
    self.table_name = "pay_periods"
  end

  class MigrationPayrollItem < ApplicationRecord
    self.table_name = "payroll_items"
    belongs_to :pay_period, class_name: "NormalizeStoredPayRatePrecision::MigrationPayPeriod"
  end

  def up
    say_with_time "Rounding employee pay rates to cents" do
      MigrationEmployee.where.not(pay_rate: nil).update_all("pay_rate = ROUND(pay_rate, 2)")
    end

    say_with_time "Rounding employee wage rates to cents" do
      MigrationEmployeeWageRate.where.not(rate: nil).update_all("rate = ROUND(rate, 2)")
    end

    say_with_time "Rounding editable payroll item rates to cents" do
      editable_payroll_items.find_each do |payroll_item|
        normalized_custom_columns = normalize_custom_columns_data(payroll_item.custom_columns_data)
        normalized_pay_rate = round_currency_value(payroll_item.pay_rate)

        next if normalized_custom_columns == payroll_item.custom_columns_data &&
                normalized_pay_rate == payroll_item.pay_rate

        payroll_item.update_columns(
          pay_rate: normalized_pay_rate,
          custom_columns_data: normalized_custom_columns,
          updated_at: Time.current
        )
      end
    end
  end

  def down
    # irreversible data cleanup
  end

  private

  def editable_payroll_items
    MigrationPayrollItem.joins(:pay_period).where(pay_periods: { status: %w[draft calculated approved] })
  end

  def normalize_custom_columns_data(custom_columns_data)
    data = (custom_columns_data || {}).deep_dup
    entries = Array(data["wage_rate_hours"] || data[:wage_rate_hours])
    return data if entries.empty?

    normalized_entries = entries.map do |entry|
      normalized_entry = entry.respond_to?(:to_h) ? entry.to_h.deep_dup : {}
      next normalized_entry if normalized_entry.empty?

      raw_rate = normalized_entry["rate"] || normalized_entry[:rate]
      rounded_rate = round_currency_value(raw_rate)
      normalized_entry["rate"] = rounded_rate.to_f if normalized_entry.key?("rate")
      normalized_entry[:rate] = rounded_rate.to_f if normalized_entry.key?(:rate)
      normalized_entry
    end

    if data.key?("wage_rate_hours")
      data["wage_rate_hours"] = normalized_entries
    else
      data[:wage_rate_hours] = normalized_entries
    end

    data
  end

  def round_currency_value(value)
    return value if value.nil?

    BigDecimal(value.to_s).round(2)
  end
end
