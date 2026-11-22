# frozen_string_literal: true

# One effective-dated version of an employee's pay rate and pay basis.
# Rows are written only by EmployeeCompensationChangeService (or the M3-4
# baseline backfill); employees.pay_rate caches the version in effect today.
class EmployeeCompensationChange < ApplicationRecord
  include EffectiveDatedCompensationVersion

  SNAPSHOT_ATTRIBUTES = %w[pay_rate employment_type salary_type pay_frequency contractor_pay_type].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User", optional: true

  validates :pay_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :employment_type, inclusion: { in: Employee::EMPLOYMENT_TYPES }
  validates :effective_on, uniqueness: { scope: :employee_id }

  def hourly?
    employment_type == "hourly"
  end

  def contractor_hourly?
    employment_type == "contractor" && contractor_pay_type == "hourly"
  end

  def hourly_pay_basis?
    hourly? || contractor_hourly?
  end

  def variable_salary?
    employment_type == "salary" && salary_type == "variable"
  end

  def snapshot
    SNAPSHOT_ATTRIBUTES.index_with { |attribute| public_send(attribute) }
  end
end
