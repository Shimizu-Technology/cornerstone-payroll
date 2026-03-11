# frozen_string_literal: true

class PayPeriod < ApplicationRecord
  TAX_SYNC_STATUSES = %w[pending syncing synced failed].freeze
  MAX_SYNC_ATTEMPTS = 5

  # CPR-71: correction lifecycle
  CORRECTION_STATUSES = %w[voided correction].freeze

  belongs_to :company
  has_many :payroll_items, dependent: :destroy

  # CPR-71: correction chain associations
  belongs_to :source_pay_period,
             class_name: "PayPeriod",
             foreign_key: :source_pay_period_id,
             optional: true
  belongs_to :superseded_by,
             class_name: "PayPeriod",
             foreign_key: :superseded_by_id,
             optional: true
  belongs_to :voided_by,
             class_name: "User",
             foreign_key: :voided_by_id,
             optional: true

  # A voided period may have one correction run that supersedes it.
  has_one :correction_run,
          class_name: "PayPeriod",
          foreign_key: :source_pay_period_id,
          inverse_of: :source_pay_period

  # CPR-71: correction audit trail
  has_many :correction_events,
           class_name: "PayPeriodCorrectionEvent",
           dependent: :restrict_with_error

  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :pay_date, presence: true
  validates :status, inclusion: { in: %w[draft calculated approved committed] }
  validates :tax_sync_status, inclusion: { in: TAX_SYNC_STATUSES }, allow_nil: true
  validates :correction_status,
            inclusion: { in: CORRECTION_STATUSES },
            allow_nil: true
  validates :source_pay_period_id,
            presence: true,
            if: :correction_run?
  validate :end_date_after_start_date
  validate :pay_date_after_end_date

  scope :draft, -> { where(status: "draft") }
  scope :calculated, -> { where(status: "calculated") }
  scope :approved, -> { where(status: "approved") }
  scope :committed, -> { where(status: "committed") }
  scope :for_year, ->(year) { where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)) }
  scope :tax_sync_pending_or_failed, -> { where(tax_sync_status: %w[pending failed]) }

  # CPR-71: correction scopes
  scope :voided, -> { where(correction_status: "voided") }
  scope :correction_runs, -> { where(correction_status: "correction") }
  scope :active_periods, -> { where(correction_status: nil) }

  def draft?
    status == "draft"
  end

  def calculated?
    status == "calculated"
  end

  def approved?
    status == "approved"
  end

  def committed?
    status == "committed"
  end

  def can_edit?
    !committed? && !voided?
  end

  # CPR-71: correction lifecycle predicates
  def voided?
    correction_status == "voided"
  end

  def correction_run?
    correction_status == "correction"
  end

  def can_void?
    committed? && !voided? && superseded_by_id.nil?
  end

  def can_create_correction_run?
    voided? && superseded_by_id.nil?
  end

  def period_description
    "#{start_date.strftime('%m/%d/%Y')} - #{end_date.strftime('%m/%d/%Y')}"
  end

  # Tax sync lifecycle
  def generate_idempotency_key!
    self.tax_sync_idempotency_key ||= "cpr-#{id}-#{committed_at&.to_i || Time.current.to_i}"
  end

  def mark_syncing!
    update!(
      tax_sync_status: "syncing",
      tax_sync_attempts: tax_sync_attempts + 1
    )
  end

  def mark_synced!
    update!(
      tax_sync_status: "synced",
      tax_synced_at: Time.current,
      tax_sync_last_error: nil
    )
  end

  def mark_sync_failed!(error_message)
    update!(
      tax_sync_status: "failed",
      tax_sync_last_error: error_message.to_s.truncate(1000)
    )
  end

  def can_retry_sync?
    committed? && tax_sync_status.in?(%w[failed pending])
  end

  def max_attempts_reached?
    tax_sync_attempts >= MAX_SYNC_ATTEMPTS
  end

  private

  def end_date_after_start_date
    return unless start_date && end_date

    if end_date <= start_date
      errors.add(:end_date, "must be after start date")
    end
  end

  def pay_date_after_end_date
    return unless pay_date && end_date

    if pay_date < end_date
      errors.add(:pay_date, "must be on or after end date")
    end
  end
end
