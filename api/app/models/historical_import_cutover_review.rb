# frozen_string_literal: true

class HistoricalImportCutoverReview < ApplicationRecord
  STATUSES = %w[pending verified approved failed].freeze
  ATTESTATIONS = {
    "source_restore" => "A retained original was downloaded and opened without signing in to QuickBooks.",
    "history_review" => "Register, employee, tax, deduction, and check history were reviewed in Cornerstone Payroll.",
    "backup_restore" => "The production database and private source-storage backup and restore procedure was rehearsed or approved.",
    "rollback_owner" => "A rollback owner can disable historical payroll without deleting the retained evidence."
  }.freeze
  APPROVAL_ACKNOWLEDGEMENT = "I approve this verified QuickBooks history for lock and QuickBooks cutover."

  belongs_to :company
  belongs_to :historical_import_batch
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :historical_import_batch_id, uniqueness: true
  validates :approval_notes, length: { maximum: 2_000 }, allow_blank: true
  validates :verification_error, length: { maximum: 2_000 }, allow_blank: true
  validate :company_matches_batch
  validate :approved_fields_are_complete, if: :approved?

  before_update :prevent_approved_review_update
  before_destroy :prevent_destroy

  def evidence_passed?
    evidence.to_h["passed"] == true && evidence_digest.present? && verified_at.present?
  end

  def exceptions_complete?
    warning_keys = Array(evidence.to_h["exceptions"]).pluck("key")
    warning_keys.all? { |key| exception_dispositions.to_h[key].to_s.strip.present? }
  end

  def attestations_complete?
    ATTESTATIONS.keys.all? { |key| ActiveModel::Type::Boolean.new.cast(attestations.to_h[key]) }
  end

  def ready_for_approval?
    status == "verified" && evidence_passed? && exceptions_complete? && attestations_complete?
  end

  def approved?
    status == "approved"
  end

  def pending?
    status == "pending"
  end

  private

  def company_matches_batch
    return unless historical_import_batch && company_id != historical_import_batch.company_id

    errors.add(:company, "must match the historical import")
  end

  def approved_fields_are_complete
    unless historical_import_batch&.applied? || historical_import_batch&.locked?
      errors.add(:historical_import_batch, "must be applied before cutover approval")
    end
    errors.add(:base, "Cutover evidence and checklist must be complete") unless evidence_passed? && exceptions_complete? && attestations_complete?
    errors.add(:approved_by, "is required") unless approved_by
    errors.add(:approved_at, "is required") unless approved_at
    errors.add(:approval_notes, "must record remaining limitations or state none") if approval_notes.to_s.strip.blank?
    return if approval_acknowledgement == APPROVAL_ACKNOWLEDGEMENT

    errors.add(:approval_acknowledgement, "must confirm the cutover approval")
  end

  def prevent_approved_review_update
    return unless status_was == "approved"

    errors.add(:base, "Approved cutover reviews cannot be changed")
    throw(:abort)
  end

  def prevent_destroy
    errors.add(:base, "Cutover review evidence cannot be deleted")
    throw(:abort)
  end
end
