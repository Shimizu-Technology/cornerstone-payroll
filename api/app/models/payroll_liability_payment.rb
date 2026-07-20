# frozen_string_literal: true

class PayrollLiabilityPayment < ApplicationRecord
  PAYMENT_TYPES = %w[settlement reversal].freeze
  PAYMENT_METHODS = %w[check ach eftps wire cash card other].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :source_payment, class_name: "PayrollLiabilityPayment", optional: true
  belongs_to :recorded_by, class_name: "User", optional: true
  has_one :reversal_payment,
    class_name: "PayrollLiabilityPayment",
    foreign_key: :source_payment_id,
    inverse_of: :source_payment,
    dependent: :restrict_with_error
  has_many :allocations,
    class_name: "PayrollLiabilityAllocation",
    inverse_of: :payroll_liability_payment,
    dependent: :restrict_with_error
  has_many :evidence,
    class_name: "PayrollLiabilityEvidence",
    inverse_of: :payroll_liability_payment,
    dependent: :restrict_with_error

  validates :payment_type, inclusion: { in: PAYMENT_TYPES }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }
  validates :category, inclusion: { in: PayrollLiabilityEntry::CATEGORIES }
  validates :authority, :payment_date, :recorded_at, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true
  validates :amount, numericality: { greater_than: 0 }, unless: :reversal?
  validates :amount, numericality: { less_than: 0 }, if: :reversal?
  validates :source_payment, presence: true, if: :reversal?
  validates :source_payment, absence: true, unless: :reversal?
  validate :context_is_consistent

  scope :chronological, -> { order(:payment_date, :recorded_at, :id) }

  def reversal?
    payment_type == "reversal"
  end

  def reversed?
    reversal_payment.present?
  end

  def readonly?
    persisted?
  end

  private

  def context_is_consistent
    return if company.blank? || pay_period.blank?

    errors.add(:company, "must match the pay period company") if company_id != pay_period.company_id
    if recorded_by.present? && recorded_by.organization_id != company.organization_id
      errors.add(:recorded_by, "must belong to the payment company's organization")
    end
    return if source_payment.blank?

    errors.add(:source_payment, "must belong to the same pay period") if source_payment.pay_period_id != pay_period_id
    errors.add(:source_payment, "must belong to the same company") if source_payment.company_id != company_id
    errors.add(:source_payment, "cannot itself be a reversal") if source_payment.reversal?
    errors.add(:source_payment, "must have the same recipient") if source_payment.authority != authority
    errors.add(:source_payment, "must have the same category") if source_payment.category != category
  end
end
