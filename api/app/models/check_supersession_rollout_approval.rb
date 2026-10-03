# frozen_string_literal: true

# Created only after explicit rollout approval. No production record is seeded.
class CheckSupersessionRolloutApproval < ApplicationRecord
  belongs_to :company
  belongs_to :approved_by, class_name: "User"

  validates :company_id, uniqueness: true
  validates :reason, presence: true, length: { minimum: 20 }
  validate :authorized_approver

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def authorized_approver
    return if company.blank? || approved_by.blank?
    return if company.live_payroll? && approved_by.active? &&
              approved_by.organization_id == company.organization_id &&
              approved_by.role.in?(%w[super_admin org_admin])

    errors.add(:base, "An active organization administrator must approve a live company")
  end

  def prevent_mutation
    errors.add(:base, "Rollout approval is append-only")
    throw :abort
  end
end
