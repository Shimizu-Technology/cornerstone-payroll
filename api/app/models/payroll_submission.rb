# frozen_string_literal: true

# One numbered revision of a client's payroll package for a period. Revisions
# are immutable once saved; a correction or replaced file is a new revision.
class PayrollSubmission < ApplicationRecord
  belongs_to :company
  belongs_to :period, class_name: "PayrollSubmissionPeriod", foreign_key: :payroll_submission_period_id, inverse_of: :submissions
  belongs_to :submitted_by, class_name: "User", optional: true
  belongs_to :acknowledged_by, class_name: "User", optional: true
  has_many :submission_documents, -> { order(:position, :id) }, class_name: "PayrollSubmissionDocument",
    inverse_of: :submission, dependent: :restrict_with_error

  has_many :submission_imports, class_name: "PayrollSubmissionImport", dependent: :restrict_with_error
  has_many :payroll_imports, through: :submission_imports

  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :submitted_at, :content_fingerprint, :request_fingerprint, presence: true
  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  validates :changes_link_url, length: { maximum: 2000 }, allow_nil: true
  validates :notes, length: { maximum: 5000 }, allow_nil: true
  validate :period_shares_company
  validate :no_changes_has_no_rows
  validate :immutable_after_create, on: :update

  # Only staff acknowledgement may change after a revision is saved.
  MUTABLE_AFTER_CREATE = %w[acknowledged_by_id acknowledged_at updated_at].freeze

  def acknowledged?
    acknowledged_at.present?
  end

  def revel_document
    submission_documents.find { |document| document.role == "revel_payroll" }
  end

  private

  def period_shares_company
    errors.add(:period, "must belong to the same company") if period && period.company_id != company_id
  end

  def no_changes_has_no_rows
    errors.add(:change_rows, "must be empty when there are no changes this period") if no_changes && change_rows.present?
  end

  def immutable_after_create
    changed = changes_to_save.keys - MUTABLE_AFTER_CREATE
    errors.add(:base, "A sent revision cannot be edited. Send a new revision instead.") if changed.any?
  end
end
