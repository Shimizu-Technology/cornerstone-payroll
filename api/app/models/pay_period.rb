# frozen_string_literal: true

class PayPeriod < ApplicationRecord
  TAX_SYNC_STATUSES = %w[pending syncing synced failed].freeze
  MAX_SYNC_ATTEMPTS = 5

  # CPR-71: correction lifecycle
  CORRECTION_STATUSES = %w[voided correction].freeze

  # Cycle distinguishes regular pay periods from supplemental periods that
  # exist solely to carry a single-employee corrective paycheck. A
  # supplemental is a real reportable period (it gets its own check #s,
  # tax sync, FIT auto-deposit, transmittal, etc.) but is *linked* to the
  # original period via corrects_pay_period_id so the UI can surface it
  # inline on the original period's detail page. Supplementals have
  # correction_status NULL — they are NOT part of CPR-71's void+redo
  # correction chain.
  CYCLES = %w[regular supplemental].freeze

  belongs_to :company
  has_many :payroll_items, dependent: :destroy
  has_many :pay_period_excluded_employees, dependent: :destroy
  has_many :excluded_employees, through: :pay_period_excluded_employees, source: :employee
  has_many :time_tracking_imports, dependent: :destroy
  has_many :payroll_intake_sessions, dependent: :destroy
  has_many :non_employee_checks, dependent: :destroy
  has_many :check_print_runs, dependent: :restrict_with_error
  has_many :loan_transactions, dependent: :nullify
  has_one :transmittal, dependent: :destroy
  has_one :check_signoff_sheet, dependent: :destroy
  has_one :form500_filing, dependent: :destroy
  has_many :payroll_liability_postings, dependent: :restrict_with_error

  # Corrective paycheck linkage — original ←──── supplemental
  # A regular period may have many supplementals (one per correction).
  belongs_to :corrects_pay_period,
             class_name: "PayPeriod",
             foreign_key: :corrects_pay_period_id,
             optional: true,
             inverse_of: :supplemental_pay_periods
  has_many :supplemental_pay_periods,
           -> { where(cycle: "supplemental").order(:pay_date, :id) },
           class_name: "PayPeriod",
           foreign_key: :corrects_pay_period_id,
           inverse_of: :corrects_pay_period,
           dependent: :restrict_with_error

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
          -> { where(correction_status: "correction").order(id: :desc) },
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
  validates :cycle, inclusion: { in: CYCLES }
  validates :corrects_pay_period_id,
            presence: true,
            if: :supplemental?
  validate :end_date_after_start_date
  validate :pay_date_after_end_date
  validate :supplemental_target_must_be_regular

  scope :draft, -> { where(status: "draft") }
  scope :calculated, -> { where(status: "calculated") }
  scope :approved, -> { where(status: "approved") }
  scope :committed, -> { where(status: "committed") }
  scope :reportable_committed, -> { committed.where(correction_status: [ nil, "correction" ]) }
  scope :for_year, ->(year) { where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)) }
  scope :tax_sync_pending_or_failed, -> { where(tax_sync_status: %w[pending failed]) }
  # Dates are required for normal records; NULLS LAST is intentionally kept in
  # both directions so any legacy/malformed rows never displace real pay periods
  # at the top of operator-facing lists.
  scope :period_chronological, -> {
    order(Arel.sql("start_date ASC NULLS LAST, end_date ASC NULLS LAST, pay_date ASC NULLS LAST, id DESC"))
  }
  scope :period_reverse_chronological, -> {
    order(Arel.sql("start_date DESC NULLS LAST, end_date DESC NULLS LAST, pay_date DESC NULLS LAST, id DESC"))
  }
  # Cycle scopes
  scope :regular_cycle, -> { where(cycle: "regular") }
  scope :supplemental_cycle, -> { where(cycle: "supplemental") }

  # CPR-71: correction scopes
  scope :voided, -> { where(correction_status: "voided") }
  scope :correction_runs, -> { where(correction_status: "correction") }
  # "Reportable" means any non-voided period in the correction chain: the original
  # run (`nil`) or a correction run. Kept separate from `reportable_committed`
  # because drafts/calculated/approved correction runs can still be editable.
  scope :reportable_periods, -> { where(correction_status: [ nil, "correction" ]) }
  # Backward-compatible alias. "Active" here means non-voided, not "original only."
  scope :active_periods, -> { reportable_periods }

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

  def supplemental?
    cycle == "supplemental"
  end

  def regular_cycle?
    cycle == "regular"
  end

  # Only regular, currently-committed, non-voided periods can be the
  # target of a corrective paycheck. (Correcting a supplemental, a voided
  # period, or a correction run is intentionally disallowed; if a
  # supplemental itself is wrong, void it through the existing
  # PayPeriodCorrectionService flow.)
  def can_issue_corrective_paycheck?
    regular_cycle? && committed? && !voided? && correction_status.nil?
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

  def can_delete_draft_correction_run?
    correction_run? && draft? && !correction_events.exists?
  end

  def period_description
    "#{start_date.strftime('%m/%d/%Y')} - #{end_date.strftime('%m/%d/%Y')}"
  end

  # Tax sync lifecycle
  def generate_idempotency_key!
    self.tax_sync_idempotency_key ||= "cpr-#{id}-#{committed_at&.to_i || Time.current.to_i}"
  end

  def tax_sync_reset_attributes(reference_time: Time.current)
    {
      tax_sync_status: "pending",
      tax_sync_attempts: 0,
      tax_sync_last_error: nil,
      tax_synced_at: nil,
      tax_sync_idempotency_key: "cpr-#{id}-#{reference_time.to_i}"
    }
  end

  def tax_sync_disabled_attributes
    {
      tax_sync_status: nil,
      tax_sync_attempts: 0,
      tax_sync_last_error: nil,
      tax_synced_at: nil,
      tax_sync_idempotency_key: nil
    }
  end

  def tax_sync_refresh_attributes(reference_time: Time.current)
    PayrollTaxSyncService.configured? ? tax_sync_reset_attributes(reference_time: reference_time) : tax_sync_disabled_attributes
  end

  def prepare_tax_sync!
    update!(tax_sync_reset_attributes)
  end

  def prepare_tax_sync_if_configured!
    update!(tax_sync_refresh_attributes)
    PayrollTaxSyncService.configured?
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

  def supplemental_target_must_be_regular
    return unless supplemental? && corrects_pay_period.present?

    unless corrects_pay_period.regular_cycle?
      errors.add(:corrects_pay_period_id,
                 "must reference a regular (non-supplemental) pay period")
    end
  end
end
