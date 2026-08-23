# frozen_string_literal: true

class CompanyPaySchedule < ApplicationRecord
  FREQUENCIES = %w[weekly biweekly semimonthly monthly].freeze
  PERIOD_RULES = %w[manual weekly biweekly semimonthly].freeze
  PAY_DATE_RULES = %w[manual days_after_period_end].freeze
  SOURCES = %w[operator_confirmed production_inferred legacy_system_default].freeze
  CONFIRMATION_STATUSES = %w[confirmed needs_confirmation].freeze

  belongs_to :company
  belongs_to :confirmed_by, class_name: "User", optional: true
  has_many :pay_periods, dependent: :nullify

  validates :frequency, inclusion: { in: FREQUENCIES }
  validates :period_rule, inclusion: { in: PERIOD_RULES }
  validates :pay_date_rule, inclusion: { in: PAY_DATE_RULES }
  validates :source, inclusion: { in: SOURCES }
  validates :confirmation_status, inclusion: { in: CONFIRMATION_STATUSES }
  validates :timezone, :effective_on, presence: true
  validates :confirmed_by, :confirmed_at, presence: true, if: :confirmed?
  validates :notes, presence: true, length: { minimum: 5 }, if: :confirmed?
  validates :period_start_weekday, inclusion: { in: 0..6 }, allow_nil: true
  validates :pay_date_offset_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 31 },
            allow_nil: true
  validate :ends_on_not_before_effective_on
  validate :automatic_period_rule_has_weekday
  validate :biweekly_rule_has_aligned_anchor
  validate :automatic_pay_date_rule_has_offset

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

  def manual_dates?
    period_rule == "manual" || pay_date_rule == "manual"
  end

  private

  def ends_on_not_before_effective_on
    return if ends_on.blank? || effective_on.blank? || ends_on >= effective_on

    errors.add(:ends_on, "must be on or after the effective date")
  end

  def automatic_period_rule_has_weekday
    return unless period_rule.in?(%w[weekly biweekly]) && period_start_weekday.nil?

    errors.add(:period_start_weekday, "is required for weekly and biweekly schedules")
  end

  def biweekly_rule_has_aligned_anchor
    return unless period_rule == "biweekly"

    if period_anchor_date.blank?
      errors.add(:period_anchor_date, "is required for a biweekly schedule")
    elsif period_start_weekday.present? && period_anchor_date.wday != period_start_weekday
      errors.add(:period_anchor_date, "must fall on the configured period start weekday")
    end
  end

  def automatic_pay_date_rule_has_offset
    return unless pay_date_rule == "days_after_period_end" && pay_date_offset_days.nil?

    errors.add(:pay_date_offset_days, "is required when pay date is based on the period end")
  end
end
