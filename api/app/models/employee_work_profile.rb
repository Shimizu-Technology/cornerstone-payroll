# frozen_string_literal: true

class EmployeeWorkProfile < ApplicationRecord
  PAY_BASES = %w[hourly salary contractor].freeze
  OVERTIME_STATUSES = %w[exempt nonexempt needs_review].freeze
  TIMEKEEPING_MODES = %w[imported manual schedule_with_exceptions].freeze
  SOURCES = %w[operator_confirmed production_migration imported legacy_system_default].freeze
  CONFIRMATION_STATUSES = %w[confirmed needs_confirmation].freeze
  WEEKDAY_KEYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :confirmed_by, class_name: "User", optional: true
  has_many :daily_time_records, dependent: :restrict_with_error

  validates :effective_on, :pay_basis, :overtime_status, :timekeeping_mode, :source, :confirmation_status, presence: true
  validates :effective_on, uniqueness: { scope: :employee_id }
  validates :pay_basis, inclusion: { in: PAY_BASES }
  validates :overtime_status, inclusion: { in: OVERTIME_STATUSES }
  validates :timekeeping_mode, inclusion: { in: TIMEKEEPING_MODES }
  validates :source, inclusion: { in: SOURCES }
  validates :confirmation_status, inclusion: { in: CONFIRMATION_STATUSES }
  validates :standard_weekly_hours, numericality: { greater_than: 0, less_than_or_equal_to: 168 }, allow_nil: true
  validates :exemption_reason, presence: true, length: { minimum: 10 }, if: :exempt?
  validates :confirmed_by, :confirmed_at, presence: true, if: :confirmed?
  validate :company_matches_employee
  validate :pay_basis_matches_employee
  validate :ends_on_not_before_effective_on
  validate :schedule_is_valid
  validate :salary_schedule_requirements
  validate :hourly_or_contractor_cannot_be_exempt
  validate :effective_dates_do_not_overlap

  scope :effective_on, ->(date) {
    where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", date, date)
      .order(effective_on: :desc)
  }

  def self.for_date(employee_id, date)
    effective_on(date).find_by(employee_id: employee_id)
  end

  def confirmed?
    confirmation_status == "confirmed"
  end

  def exempt?
    overtime_status == "exempt"
  end

  def nonexempt?
    overtime_status == "nonexempt"
  end

  def scheduled_hours_for(date)
    BigDecimal(daily_schedule.to_h.fetch(WEEKDAY_KEYS.fetch(date.to_date.wday), 0).to_s)
  rescue ArgumentError, KeyError
    0.to_d
  end

  def total_scheduled_hours
    WEEKDAY_KEYS.sum { |day| BigDecimal(daily_schedule.to_h.fetch(day, 0).to_s) }
  rescue ArgumentError
    0.to_d
  end

  private

  def company_matches_employee
    return if employee.blank? || company_id == employee.company_id

    errors.add(:company, "must match the employee's company")
  end

  def pay_basis_matches_employee
    return if employee.blank? || pay_basis == employee.employment_type

    errors.add(:pay_basis, "must match the employee's current employment type")
  end

  def ends_on_not_before_effective_on
    return if ends_on.blank? || effective_on.blank? || ends_on >= effective_on

    errors.add(:ends_on, "must be on or after the effective date")
  end

  def schedule_is_valid
    unknown = daily_schedule.to_h.keys - WEEKDAY_KEYS
    errors.add(:daily_schedule, "contains unsupported weekdays: #{unknown.join(', ')}") if unknown.any?

    daily_schedule.to_h.each do |day, hours|
      value = BigDecimal(hours.to_s)
      errors.add(:daily_schedule, "#{day} must be between 0 and 24 hours") unless value.between?(0, 24)
    rescue ArgumentError
      errors.add(:daily_schedule, "#{day} must be a number")
    end
  end

  def salary_schedule_requirements
    return unless pay_basis == "salary"

    errors.add(:standard_weekly_hours, "is required for salary timekeeping") if standard_weekly_hours.blank?
    return unless timekeeping_mode == "schedule_with_exceptions"

    if daily_schedule.to_h.blank?
      errors.add(:daily_schedule, "is required for schedule-based salary timekeeping")
    elsif standard_weekly_hours.present? && total_scheduled_hours != standard_weekly_hours.to_d
      errors.add(:daily_schedule, "must total the standard weekly hours")
    end
  end

  def hourly_or_contractor_cannot_be_exempt
    return if pay_basis == "salary" || !exempt?

    errors.add(:overtime_status, "cannot be exempt unless the worker is salaried")
  end

  def effective_dates_do_not_overlap
    return if employee.blank? || effective_on.blank?

    range_end = ends_on || Date.new(9999, 12, 31)
    overlap = employee.employee_work_profiles
      .where.not(id: id)
      .where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", range_end, effective_on)
      .exists?
    errors.add(:effective_on, "overlaps another work profile") if overlap
  end
end
