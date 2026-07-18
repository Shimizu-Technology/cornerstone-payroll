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
  has_many :line_items,
           -> { ordered },
           class_name: "NonEmployeeCheckLineItem",
           dependent: :destroy,
           inverse_of: :non_employee_check

  accepts_nested_attributes_for :line_items, allow_destroy: true

  before_validation :normalize_payment_period_type
  before_validation :clear_inapplicable_tax_period_fields

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
  validate :line_item_total_matches_amount
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
    with_lock do
      raise ArgumentError, "Cannot print a voided check" if voided?

      update!(
        printed_at: printed_at || Time.current,
        print_count: print_count + 1
      )
    end
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

  def voucher_line_items
    loaded = line_items.to_a.reject(&:marked_for_destruction?)
    return loaded if loaded.any?

    [
      NonEmployeeCheckLineItem.new(
        non_employee_check: self,
        description: memo.presence || description.presence || check_type.to_s.titleize,
        reference_number: reference_number,
        service_period: voucher_period_label,
        amount: amount,
        position: 0
      )
    ]
  end

  private

  def normalize_payment_period_type
    self.payment_period_type = if pay_period_id.present?
      "pay_period"
    else
      payment_period_type.presence || "none"
    end
  end

  def clear_inapplicable_tax_period_fields
    case payment_period_type
    when "month"
      self.tax_quarter = nil
    when "quarter"
      self.tax_month = nil
    when "year"
      self.tax_month = nil
      self.tax_quarter = nil
    else
      self.tax_year = nil
      self.tax_month = nil
      self.tax_quarter = nil
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

  def line_item_total_matches_amount
    active_line_items = line_items.reject(&:marked_for_destruction?)
    return if active_line_items.empty?
    return if amount.blank?

    total = active_line_items.sum { |item| item.amount.to_d }
    return if total == amount.to_d

    errors.add(:line_items, "must total the check amount")
  end

  def voucher_period_label
    case payment_period_type
    when "month"
      return nil if tax_year.blank? || tax_month.blank?
      "#{Date::MONTHNAMES[tax_month]} #{tax_year}"
    when "quarter"
      return nil if tax_year.blank? || tax_quarter.blank?
      "Q#{tax_quarter} #{tax_year}"
    when "year"
      tax_year&.to_s
    when "pay_period"
      return nil unless pay_period
      "#{pay_period.start_date.strftime('%m/%d/%Y')} - #{pay_period.end_date.strftime('%m/%d/%Y')}"
    end
  end
end
