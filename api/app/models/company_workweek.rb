# frozen_string_literal: true

class CompanyWorkweek < ApplicationRecord
  SOURCES = CompanyPaySchedule::SOURCES
  CONFIRMATION_STATUSES = CompanyPaySchedule::CONFIRMATION_STATUSES

  belongs_to :company
  belongs_to :confirmed_by, class_name: "User", optional: true
  has_many :pay_periods, dependent: :nullify

  validates :starts_on_weekday, inclusion: { in: 0..6 }
  validates :starts_at_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1.day.in_minutes }
  validates :source, inclusion: { in: SOURCES }
  validates :confirmation_status, inclusion: { in: CONFIRMATION_STATUSES }
  validates :timezone, :effective_on, presence: true
  validates :confirmed_by, :confirmed_at, presence: true, if: :confirmed?
  validates :notes, presence: true, length: { minimum: 5 }, if: :confirmed?
  validate :ends_on_not_before_effective_on
  validate :date_only_boundary_must_start_at_midnight, if: :will_save_change_to_starts_at_minutes?

  scope :effective_on, ->(date) {
    where("effective_on <= ? AND (ends_on IS NULL OR ends_on >= ?)", date, date)
      .order(effective_on: :desc)
  }

  def self.for_date(company_id, date)
    effective_on(date).find_by(company_id: company_id)
  end

  def confirmed?
    confirmation_status == "confirmed"
  end

  private

  def ends_on_not_before_effective_on
    return if ends_on.blank? || effective_on.blank? || ends_on >= effective_on

    errors.add(:ends_on, "must be on or after the effective date")
  end

  def date_only_boundary_must_start_at_midnight
    return if starts_at_minutes.to_i.zero?

    errors.add(:starts_at_minutes, "must be midnight until timestamp-based workweek boundaries are supported")
  end
end
