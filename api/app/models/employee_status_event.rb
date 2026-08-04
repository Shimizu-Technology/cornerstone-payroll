# frozen_string_literal: true

class EmployeeStatusEvent < ApplicationRecord
  EVENT_TYPES = %w[terminated reactivated].freeze
  STATUSES = %w[active inactive terminated].freeze
  SOURCES = %w[operator production_migration].freeze
  TERMINATION_REASONS = %w[voluntary involuntary layoff reduction_in_force end_of_contract retirement other].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :previous_status, :resulting_status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :effective_date, presence: true
  validates :reason_category, inclusion: { in: TERMINATION_REASONS }, allow_blank: true
  validate :company_matches_employee
  validate :last_worked_not_after_effective_date
  validate :valid_transition

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def company_matches_employee
    errors.add(:company, "must match the employee's company") if employee && company_id != employee.company_id
  end

  def last_worked_not_after_effective_date
    return if last_worked_on.blank? || effective_date.blank? || last_worked_on <= effective_date

    errors.add(:last_worked_on, "cannot be after the effective date")
  end

  def valid_transition
    expected = event_type == "terminated" ? "terminated" : "active"
    errors.add(:resulting_status, "does not match the event type") unless resulting_status == expected
  end

  def prevent_mutation
    errors.add(:base, "Employee status history is immutable")
    throw :abort
  end
end
