# frozen_string_literal: true

class EmployeeWageRate < ApplicationRecord
  belongs_to :employee

  around_save :persist_under_employee_lock
  around_destroy :destroy_under_employee_lock

  before_validation :normalize_rate_precision

  validates :label, presence: true
  validates :label, uniqueness: { scope: :employee_id }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :primary, -> { where(is_primary: true) }

  def self.create_with_employee_lock(employee:, attributes:)
    rate = employee.employee_wage_rates.build(attributes)
    rate.send(:with_employee_mutation_lock) { rate.save }
    rate
  end

  def update_with_employee_lock(attributes)
    with_employee_mutation_lock do
      reload
      update(attributes)
    end
  end

  def destroy_with_employee_lock!
    with_employee_mutation_lock do
      reload
      destroy!
    end
  end

  private

  def with_employee_mutation_lock
    return yield if @employee_mutation_locked

    employee.company.with_lock do
      employee.with_lock do
        @employee_mutation_locked = true
        begin
          yield
        ensure
          @employee_mutation_locked = false
        end
      end
    end
  end

  def persist_under_employee_lock
    with_employee_mutation_lock do
      setup_changed = new_record? || (changes_to_save.keys & %w[rate active is_primary]).any?
      yield
      invalidate_intake_confirmation! if setup_changed
    end
  end

  def destroy_under_employee_lock
    with_employee_mutation_lock do
      yield
      invalidate_intake_confirmation!
    end
  end

  def invalidate_intake_confirmation!
    changed = Employee.where(id: employee_id).where.not(intake_exception: {})
      .where.not(intake_payroll_confirmed_at: nil)
      .update_all(intake_payroll_confirmed_at: nil, updated_at: Time.current)
    employee.reload if changed.positive? && association(:employee).loaded?
  end

  def normalize_rate_precision
    return if rate.nil?

    self.rate = BigDecimal(rate.to_s).round(2)
  end
end
