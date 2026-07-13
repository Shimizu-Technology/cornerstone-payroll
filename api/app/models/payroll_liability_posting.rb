# frozen_string_literal: true

class PayrollLiabilityPosting < ApplicationRecord
  POSTING_TYPES = %w[commit historical_backfill replacement reversal].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :source_posting, class_name: "PayrollLiabilityPosting", optional: true
  belongs_to :posted_by, class_name: "User", optional: true
  has_one :reversal_posting,
          class_name: "PayrollLiabilityPosting",
          foreign_key: :source_posting_id,
          inverse_of: :source_posting,
          dependent: :restrict_with_error
  has_many :entries,
           class_name: "PayrollLiabilityEntry",
           inverse_of: :payroll_liability_posting,
           dependent: :restrict_with_error

  validates :posting_type, inclusion: { in: POSTING_TYPES }
  validates :liability_date, :posted_at, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true
  validates :source_posting_id, presence: true, if: :reversal?
  validates :source_posting_id, absence: true, unless: :reversal?
  validate :company_matches_pay_period
  validate :posted_by_matches_company_organization
  validate :source_posting_matches_context

  scope :chronological, -> { order(:liability_date, :posted_at, :id) }
  scope :reversals, -> { where(posting_type: "reversal") }
  scope :source_postings, -> { where.not(posting_type: "reversal") }

  def reversal?
    posting_type == "reversal"
  end

  def reversed?
    reversal_posting.present?
  end

  def readonly?
    persisted?
  end

  private

  def company_matches_pay_period
    return if company_id.blank? || pay_period.blank? || company_id == pay_period.company_id

    errors.add(:company_id, "must match the pay period company")
  end

  def source_posting_matches_context
    return if source_posting.blank?

    errors.add(:source_posting, "must belong to the same pay period") if source_posting.pay_period_id != pay_period_id
    errors.add(:source_posting, "must belong to the same company") if source_posting.company_id != company_id
    errors.add(:source_posting, "cannot itself be a reversal") if source_posting.reversal?
  end

  def posted_by_matches_company_organization
    return if posted_by.blank? || company.blank?
    return if posted_by.organization_id == company.organization_id

    errors.add(:posted_by, "must belong to the posting company's organization")
  end
end
