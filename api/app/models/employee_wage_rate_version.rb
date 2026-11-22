# frozen_string_literal: true

# One effective-dated version of an employee wage rate's label, amount,
# primary flag and active flag. Written only by EmployeeCompensationChangeService
# (or the M3-4 baseline backfill); employee_wage_rates caches today's version.
class EmployeeWageRateVersion < ApplicationRecord
  include EffectiveDatedCompensationVersion

  SNAPSHOT_ATTRIBUTES = %w[label rate is_primary active].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :employee_wage_rate
  belongs_to :created_by, class_name: "User", optional: true

  validates :label, presence: true
  validates :rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :effective_on, uniqueness: { scope: :employee_wage_rate_id }

  validate :wage_rate_matches_employee

  def wage_rate_matches_employee
    return unless employee_wage_rate && employee_wage_rate.employee_id != employee_id

    errors.add(:employee_wage_rate, "must belong to the employee")
  end
  private :wage_rate_matches_employee

  def snapshot
    SNAPSHOT_ATTRIBUTES.index_with { |attribute| public_send(attribute) }
  end

  # A read-only stand-in for the wage-rate row as it stood on this version's
  # dates. It keeps the row's id, so payroll wage-rate buckets still link to
  # employee_wage_rates, but carries this version's label, rate and flags.
  def as_wage_rate(row = employee_wage_rate)
    EmployeeWageRate.instantiate(row.attributes.merge(snapshot)).tap(&:readonly!)
  end
end
