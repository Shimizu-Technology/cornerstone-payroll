# frozen_string_literal: true

class DailyTimeRecord < ApplicationRecord
  SOURCES = %w[schedule import manual correction_reference production_backfill].freeze
  LEDGER_KEYS = %w[authoritative parallel test historical].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :employee_work_profile, optional: true
  belongs_to :supersedes, class_name: "DailyTimeRecord", optional: true
  has_one :superseding_record, class_name: "DailyTimeRecord", foreign_key: :supersedes_id, dependent: :restrict_with_error
  has_many :payroll_time_allocations, dependent: :restrict_with_error

  validates :work_date, :workweek_started_on, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :ledger_key, inclusion: { in: LEDGER_KEYS }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :scheduled_hours, :pto_hours, :holiday_hours,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 24 }
  validates :actual_worked_hours,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 24 }, allow_nil: true
  validate :company_matches_relations
  validate :supersession_is_valid
  validate :compensated_hours_fit_in_day

  before_update :prevent_in_place_mutation
  before_destroy :prevent_destroy

  scope :current, -> { where(superseded_at: nil) }
  scope :authoritative, -> { where(ledger_key: "authoritative") }

  def hours_for_overtime
    worked_hours
  end

  def worked_hours
    return actual_worked_hours.to_d unless actual_worked_hours.nil?

    [ scheduled_hours.to_d - pto_hours.to_d - holiday_hours.to_d, 0.to_d ].max
  end

  private

  def company_matches_relations
    errors.add(:company, "must match the employee's company") if employee && company_id != employee.company_id
    if employee_work_profile && employee_work_profile.employee_id != employee_id
      errors.add(:employee_work_profile, "must belong to the same employee")
    end
  end

  def supersession_is_valid
    return unless supersedes

    unless supersedes.employee_id == employee_id && supersedes.work_date == work_date && supersedes.ledger_key == ledger_key
      errors.add(:supersedes, "must replace the same employee, date, and ledger")
    end
    errors.add(:revision, "must increase by one") unless revision == supersedes.revision + 1
  end

  def compensated_hours_fit_in_day
    return unless scheduled_hours && pto_hours && holiday_hours

    total = worked_hours + pto_hours.to_d + holiday_hours.to_d
    errors.add(:base, "Worked, PTO, and holiday hours cannot exceed 24 in one day") if total > 24
  end

  def prevent_in_place_mutation
    permitted = %w[superseded_at updated_at]
    return if changes_to_save.keys.all? { |attribute| attribute.in?(permitted) }

    errors.add(:base, "Daily time records must be corrected by creating a new revision")
    throw :abort
  end

  def prevent_destroy
    errors.add(:base, "Daily time history cannot be deleted")
    throw :abort
  end
end
