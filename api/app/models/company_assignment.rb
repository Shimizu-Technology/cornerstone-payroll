# frozen_string_literal: true

class CompanyAssignment < ApplicationRecord
  WORKSPACE_ACCESS_LEVELS = %w[operator reviewer workspace_admin].freeze

  belongs_to :user
  belongs_to :company
  belongs_to :granted_by, class_name: "User", optional: true

  validates :user_id, uniqueness: { scope: :company_id }
  validates :workspace_access_level, inclusion: { in: WORKSPACE_ACCESS_LEVELS }, allow_nil: true
  validate :company_must_belong_to_user_organization
  validate :test_workspace_requires_staff_user
  validate :test_workspace_access_level_shape
  validate :grantor_must_belong_to_organization

  scope :active_access, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  private

  def company_must_belong_to_user_organization
    return if user.blank? || company.blank?
    return if user.organization_id.present? && user.organization_id == company.organization_id

    errors.add(:company, "must belong to the user's organization")
  end

  def test_workspace_requires_staff_user
    return if user.blank? || company.blank? || !company.test_workspace? || user.staff_member?

    errors.add(:company, "test workspaces are available only to payroll staff")
  end

  def test_workspace_access_level_shape
    return if company.blank?

    if company.test_workspace? && workspace_access_level.blank?
      errors.add(:workspace_access_level, "is required for a test workspace")
    elsif company.live_payroll? && workspace_access_level.present?
      errors.add(:workspace_access_level, "is only available for a test workspace")
    end
  end

  def grantor_must_belong_to_organization
    return if granted_by.blank? || company.blank?
    return if granted_by.super_admin? || granted_by.organization_id == company.organization_id

    errors.add(:granted_by, "must belong to the test workspace organization")
  end
end
