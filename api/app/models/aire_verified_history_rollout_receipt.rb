# frozen_string_literal: true

class AireVerifiedHistoryRolloutReceipt < ApplicationRecord
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :company
  belongs_to :time_tracking_source

  validates :manifest_sha256, presence: true, uniqueness: { scope: [ :time_tracking_source_id, :coverage_verified ] },
            format: { with: /\A[0-9a-f]{64}\z/ }
  validates :identity_count, :paid_source_entry_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :completed_at, presence: true
  validate :approver_can_reconcile_company, if: :coverage_verified?

  def readonly?
    persisted?
  end

  private

  def approver_can_reconcile_company
    unless StaffRolePolicy.historical_reconciliation_allowed?(approved_by, company)
      errors.add(:approved_by, "cannot approve historical reconciliation for this company")
    end
  end
end
