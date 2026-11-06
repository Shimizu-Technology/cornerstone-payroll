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

  validates :client_management, inclusion: { in: [ true, false ] }
  validate :client_management_grant_shape

  scope :active_access, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  private

  def client_management_grant_shape
    return unless client_management?

    errors.add(:client_management, "is only available for live accountant assignments") unless user&.accountant? && company&.live_payroll? && workspace_access_level.nil?
    return unless new_record? || will_save_change_to_client_management? || validation_context == :client_management_update

    actor = User.find_by(id: granted_by_id)
    unless actor&.organization_admin? && actor.payroll_access_allowed? && actor.id != user_id &&
      (actor.super_admin? || actor.organization_id == company&.organization_id)
      errors.add(:client_management, "must be granted by another active organization administrator")
    end
    unless user&.payroll_access_allowed? && company&.active? && company.organization&.active? && !expired?
      errors.add(:client_management, "requires an active user, client, organization and unexpired assignment")
    end
  end

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
