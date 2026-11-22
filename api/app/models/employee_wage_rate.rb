# frozen_string_literal: true

class EmployeeWageRate < ApplicationRecord
  VERSIONED_ATTRIBUTES = %w[label rate is_primary active].freeze

  belongs_to :employee
  # Rows are ended (active: false), never deleted; see guard_compensation_destroy.
  has_many :employee_wage_rate_versions, dependent: :restrict_with_error

  around_save :persist_under_employee_lock
  around_destroy :destroy_under_employee_lock
  before_update :guard_compensation_mutation
  before_destroy :guard_compensation_destroy, prepend: true
  after_create :record_initial_version, unless: -> { EmployeeCompensationChangeService.writing?(employee_id) }

  before_validation :normalize_rate_precision

  validates :label, presence: true
  validates :label, uniqueness: { scope: :employee_id }
  validates :rate, numericality: { greater_than_or_equal_to: 0, less_than: 1_000_000 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :primary, -> { where(is_primary: true) }

  private

  def guard_compensation_mutation
    return unless (changes_to_save.keys & VERSIONED_ATTRIBUTES).any?
    return if EmployeeCompensationChangeService.writing?(employee_id)

    raise EmployeeCompensationChangeService::CompensationMutationError,
          "Change wage rates through EmployeeCompensationChangeService so the effective date and history are recorded"
  end

  # Deleting an employee removes its history first; anything else ends the
  # rate through EmployeeCompensationChangeService instead.
  def guard_compensation_destroy
    return if destroyed_by_association

    raise EmployeeCompensationChangeService::CompensationMutationError,
          "End wage rates through EmployeeCompensationChangeService instead of deleting them"
  end

  def record_initial_version
    actor = employee.initial_compensation_actor || Current.user || Current.actor ||
      AuditActor.operator("Initial wage rate setup")
    EmployeeCompensationChangeService.record_wage_rate_created!(self, actor: actor)
  end

  def with_employee_mutation_lock
    # EmployeeCompensationChangeService already holds the company and employee
    # locks, and relocking would reload the caller's employee record.
    return yield if @employee_mutation_locked || EmployeeCompensationChangeService.writing?(employee_id)

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
    return unless changed.positive? && association(:employee).loaded?

    if EmployeeCompensationChangeService.writing?(employee_id)
      employee.intake_payroll_confirmed_at = nil
      employee.clear_attribute_changes([ :intake_payroll_confirmed_at ])
    else
      employee.reload
    end
  end

  def normalize_rate_precision
    return if rate.nil?

    self.rate = BigDecimal(rate.to_s).round(2)
  end
end
