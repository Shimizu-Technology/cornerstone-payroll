# frozen_string_literal: true

class NonEmployeeCheck < ApplicationRecord
  CHECK_TYPES = %w[contractor tax_deposit child_support garnishment vendor reimbursement other].freeze

  belongs_to :pay_period
  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true

  validates :payable_to, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :check_type, presence: true, inclusion: { in: CHECK_TYPES }

  scope :active, -> { where(voided: false) }
  scope :printed, -> { where.not(printed_at: nil) }
  scope :unprinted, -> { where(printed_at: nil, voided: false) }
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
end
