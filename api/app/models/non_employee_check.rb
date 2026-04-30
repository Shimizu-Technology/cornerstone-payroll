# frozen_string_literal: true

class NonEmployeeCheck < ApplicationRecord
  CHECK_TYPES = %w[
    contractor tax_deposit grt estimated_tax w1_balance swica
    child_support garnishment vendor reimbursement other
  ].freeze
  PAYMENT_PERIOD_TYPES = %w[none pay_period month quarter year].freeze

  # Stable identifiers for auto-generated checks. Survives user-driven renames
  # of `payable_to`. Used by the unique index that prevents duplicate
  # auto-generated checks per pay period.
  AUTO_GENERATED_TYPES = {
    fit_deposit: "fit_deposit"
  }.freeze

  belongs_to :pay_period, optional: true
  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  # Use :delete_all (not :destroy) because NonEmployeeCheckEdit#readonly? is
  # true once persisted (audit records are immutable). :destroy would call
  # `destroy` on each edit which raises ActiveRecord::ReadOnlyRecord. The DB
  # also has ON DELETE CASCADE so the edits get cleaned up either way.
  has_many :edits, -> { order(created_at: :desc) },
           class_name: "NonEmployeeCheckEdit",
           dependent: :delete_all

  before_validation :normalize_payment_period_type

  validates :payable_to, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :check_type, presence: true, inclusion: { in: CHECK_TYPES }
  validates :payment_period_type, presence: true, inclusion: { in: PAYMENT_PERIOD_TYPES }
  validates :tax_year,
            numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2100 },
            allow_nil: true
  validates :tax_quarter, numericality: { only_integer: true, in: 1..4 }, allow_nil: true
  validates :tax_month, numericality: { only_integer: true, in: 1..12 }, allow_nil: true
  validate :payment_period_fields_match_type
  # Mirrors the DB-level partial unique index `idx_ne_checks_on_company_check_num`
  # so that a duplicate `check_number` (now editable through the Edit modal)
  # surfaces as a clean 422 with a field error instead of bubbling
  # `ActiveRecord::RecordNotUnique` out of the controller as a 500.
  # `allow_nil`/`allow_blank` keep the validation aligned with the partial
  # index (which only enforces uniqueness when check_number IS NOT NULL).
  validates :check_number,
            uniqueness: { scope: :company_id, allow_nil: true },
            allow_blank: true

  scope :active, -> { where(voided: false) }
  scope :printed, -> { where.not(printed_at: nil) }
  scope :unprinted, -> { where(printed_at: nil, voided: false) }
  scope :standalone, -> { where(pay_period_id: nil) }
  scope :by_type, ->(type) { where(check_type: type) }

  def printed?
    printed_at.present?
  end

  def voided?
    voided
  end

  def mark_printed!
    raise ArgumentError, "Cannot print a voided check" if voided?

    update!(
      printed_at: printed_at || Time.current,
      print_count: print_count + 1
    )
  end

  def void!(reason:)
    raise ArgumentError, "Already voided" if voided?
    raise ArgumentError, "Void reason is required" if reason.blank?

    update!(
      voided: true,
      voided_at: Time.current,
      void_reason: reason
    )
  end

  def check_status
    return "voided" if voided?
    return "printed" if printed?
    return "unprinted" if check_number.present?
    "pending"
  end

  def standalone?
    pay_period_id.nil?
  end

  def effective_payment_date
    payment_date || pay_period&.pay_date || created_at&.to_date || Date.current
  end

  private

  def normalize_payment_period_type
    self.payment_period_type = if pay_period_id.present?
      "pay_period"
    else
      payment_period_type.presence || "none"
    end
  end

  def payment_period_fields_match_type
    if pay_period_id.present? && payment_period_type != "pay_period"
      errors.add(:payment_period_type, "must be pay_period when tied to a pay period")
    end

    case payment_period_type
    when "month"
      errors.add(:tax_year, "is required for monthly payments") if tax_year.blank?
      errors.add(:tax_month, "is required for monthly payments") if tax_month.blank?
    when "quarter"
      errors.add(:tax_year, "is required for quarterly payments") if tax_year.blank?
      errors.add(:tax_quarter, "is required for quarterly payments") if tax_quarter.blank?
    when "year"
      errors.add(:tax_year, "is required for yearly payments") if tax_year.blank?
    end
  end
end
