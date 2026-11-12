# frozen_string_literal: true

# Draft paycheck and direct-deposit PDFs staff post for the client to review.
# An unposted draft and its files stay staff-only.
class PayrollSubmissionDraft < ApplicationRecord
  belongs_to :company
  belongs_to :period, class_name: "PayrollSubmissionPeriod", foreign_key: :payroll_submission_period_id, inverse_of: :drafts
  belongs_to :paycheck_document, class_name: "ClientDocument", optional: true
  belongs_to :direct_deposit_document, class_name: "ClientDocument", optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :posted_by, class_name: "User", optional: true

  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :note, length: { maximum: 5000 }, allow_nil: true
  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  validate :has_a_file
  validate :records_share_company

  scope :posted, -> { where.not(posted_at: nil) }

  def posted?
    posted_at.present?
  end

  def documents
    [ paycheck_document, direct_deposit_document ].compact
  end

  private

  def has_a_file
    errors.add(:base, "Attach the draft paychecks, the direct deposits, or both") if paycheck_document_id.nil? && direct_deposit_document_id.nil?
  end

  def records_share_company
    errors.add(:period, "must belong to the same company") if period && period.company_id != company_id
    [ paycheck_document, direct_deposit_document ].compact.each do |document|
      errors.add(:base, "Draft files must belong to the same company") if document.company_id != company_id
    end
  end
end
