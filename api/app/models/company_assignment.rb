# frozen_string_literal: true

class CompanyAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :user_id, uniqueness: { scope: :company_id }
  validate :company_must_belong_to_user_organization
  validate :migration_rehearsal_requires_staff_user

  private

  def company_must_belong_to_user_organization
    return if user.blank? || company.blank?
    return if user.organization_id.present? && user.organization_id == company.organization_id

    errors.add(:company, "must belong to the user's organization")
  end

  def migration_rehearsal_requires_staff_user
    return if user.blank? || company.blank? || !company.migration_rehearsal? || user.staff_member?

    errors.add(:company, "migration rehearsals are available only to payroll staff")
  end
end
