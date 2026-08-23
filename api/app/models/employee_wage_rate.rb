# frozen_string_literal: true

class EmployeeWageRate < ApplicationRecord
  belongs_to :employee

  before_validation :normalize_rate_precision

  validates :label, presence: true
  validates :label, uniqueness: { scope: :employee_id }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :primary, -> { where(is_primary: true) }

  def self.create_with_employee_lock(employee:, attributes:)
    employee.with_lock do
      employee.employee_wage_rates.create(attributes)
    end
  end

  def update_with_employee_lock(attributes)
    employee.with_lock do
      reload
      update(attributes)
    end
  end

  def destroy_with_employee_lock!
    employee.with_lock do
      reload
      destroy!
    end
  end

  private

  def normalize_rate_precision
    return if rate.nil?

    self.rate = BigDecimal(rate.to_s).round(2)
  end
end
