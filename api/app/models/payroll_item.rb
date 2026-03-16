# frozen_string_literal: true

class PayrollItem < ApplicationRecord
  belongs_to :pay_period
  belongs_to :employee
  belongs_to :company
  belongs_to :voided_by_user, class_name: "User", optional: true, foreign_key: :voided_by_user_id
  has_many :check_events, dependent: :restrict_with_error

  # Sync on create only. On update, `company_matches_pay_period` enforces the
  # constraint instead, so operators cannot silently reassign across companies.
  # Uses ||= so an explicitly-passed company_id (e.g. in copy_payroll_items!)
  # is respected without triggering a pay_period reload query.
  before_validation :sync_company_from_pay_period, on: :create

  validates :employment_type, inclusion: { in: %w[hourly salary] }
  validates :pay_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :hours_worked, :overtime_hours, :holiday_hours, :pto_hours,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :company_id, presence: true
  validate :company_matches_pay_period

  # Validate that each employee only appears once per pay period
  validates :employee_id, uniqueness: { scope: :pay_period_id }

  delegate :full_name, to: :employee, prefix: true

  # ---------------------------------------------------------------------------
  # Check-related scopes
  # ---------------------------------------------------------------------------
  scope :with_check_number,  -> { where.not(check_number: nil) }
  scope :checks_only,        -> { with_check_number.where(voided: false) }
  scope :voided_checks,      -> { where(voided: true) }
  scope :printed,            -> { where.not(check_printed_at: nil) }
  scope :unprinted,          -> { where(check_printed_at: nil, voided: false) }

  # ---------------------------------------------------------------------------
  # Check lifecycle actions
  # ---------------------------------------------------------------------------

  # Mark this check as printed and log the event.
  # @param user [User]  the operator performing the print action
  # @param ip_address [String, nil]
  # @return [Hash] { already_printed: Boolean, event: CheckEvent }
  def mark_printed!(user:, ip_address: nil)
    raise ArgumentError, "Cannot mark a voided check as printed" if voided?
    raise ArgumentError, "No check number assigned" if check_number.blank?

    ApplicationRecord.transaction do
      lock! # SELECT ... FOR UPDATE — prevents concurrent print-count undercount
      raise ArgumentError, "Cannot mark a voided check as printed" if voided? # re-check under lock
      raise ArgumentError, "No check number assigned" if check_number.blank? # re-check under lock

      already_printed = check_printed_at.present?

      update!(
        check_printed_at: check_printed_at || Time.current,
        check_print_count: check_print_count + 1
      )
      event = check_events.create!(
        user: user,
        event_type: "printed",
        check_number: check_number,
        ip_address: ip_address
      )

      { already_printed: already_printed, event: event }
    end
  end

  # Void this check.  Does NOT delete the record.
  # @param user [User]   the admin performing the void
  # @param reason [String] required written reason (min 10 chars)
  # @param ip_address [String, nil]
  # @return [CheckEvent]
  def void!(user:, reason:, ip_address: nil)
    raise ArgumentError, "Already voided" if voided?
    raise ArgumentError, "No check number assigned" if check_number.blank?
    raise ArgumentError, "Void reason is required (minimum 10 characters)" if reason.blank? || reason.length < 10

    ApplicationRecord.transaction do
      lock! # SELECT ... FOR UPDATE to prevent concurrent double-void
      raise ArgumentError, "Already voided" if voided? # re-check under lock

      update!(
        voided: true,
        voided_at: Time.current,
        voided_by_user_id: user.id,
        void_reason: reason
      )
      check_events.create!(
        user: user,
        event_type: "voided",
        check_number: check_number,
        reason: reason,
        ip_address: ip_address
      )
    end
  end

  # Check status helper (used in serialisation)
  def check_status
    return "voided"   if voided?
    return "printed"  if check_printed_at.present?
    return "unprinted" if check_number.present?
    nil
  end

  def total_hours
    hours_worked.to_f + overtime_hours.to_f + holiday_hours.to_f + pto_hours.to_f
  end

  def overtime_pay
    return 0 unless hourly?

    overtime_hours.to_f * pay_rate * 1.5
  end

  def regular_pay
    return 0 unless hourly?

    hours_worked.to_f * pay_rate
  end

  def hourly?
    employment_type == "hourly"
  end

  def salary?
    employment_type == "salary"
  end

  # Calculate and store all values
  def calculate!
    calculator = PayrollCalculator.for(employee, self)
    calculator.calculate
    save!
  end

  private

  def sync_company_from_pay_period
    self.company_id ||= pay_period&.company_id
  end

  def company_matches_pay_period
    return if pay_period.blank? || company_id.blank?
    return if company_id == pay_period.company_id

    errors.add(:company_id, "must match the pay period company")
  end
end
