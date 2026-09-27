# frozen_string_literal: true

# Append-only explanation for a verified legacy row that never represented pay.
# The committed payroll item and all approvals remain available for audit.
class PayrollItemLegacyDisposition < ApplicationRecord
  REASON = "verified_empty_legacy_item"

  belongs_to :payroll_item
  belongs_to :company
  belongs_to :created_by, class_name: "User"

  validates :reason, inclusion: { in: [ REASON ] }
  validates :evidence_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :payroll_item_id, uniqueness: true
  validate :company_matches_item
  validate :committed_item_verified_empty
  before_update { raise ActiveRecord::ReadOnlyRecord, "Legacy payroll dispositions are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Legacy payroll dispositions are append-only" }

  private

  def company_matches_item
    errors.add(:company, "must match payroll item") if payroll_item && company_id != payroll_item.company_id
  end

  def committed_item_verified_empty
    return unless payroll_item

    errors.add(:payroll_item, "must be in a committed period") unless payroll_item.pay_period.committed?
    errors.add(:payroll_item, "must be verified empty") unless PayrollItemActivity.classify(payroll_item) == :verified_empty
  end
end
