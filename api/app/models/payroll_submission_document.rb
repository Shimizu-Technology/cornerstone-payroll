# frozen_string_literal: true

# A file in one submission revision. Membership never changes; the checksum is
# what the client sent, so a later archive or preview cannot alter the record.
class PayrollSubmissionDocument < ApplicationRecord
  ROLES = %w[revel_payroll changes_workbook attachment].freeze

  belongs_to :company
  belongs_to :submission, class_name: "PayrollSubmission", foreign_key: :payroll_submission_id, inverse_of: :submission_documents
  belongs_to :client_document

  validates :role, inclusion: { in: ROLES }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :file_name_snapshot, presence: true
  validate :records_share_company

  def readonly?
    persisted? && !destroyed?
  end

  private

  def records_share_company
    errors.add(:submission, "must belong to the same company") if submission && submission.company_id != company_id
    errors.add(:client_document, "must belong to the same company") if client_document && client_document.company_id != company_id
  end
end
