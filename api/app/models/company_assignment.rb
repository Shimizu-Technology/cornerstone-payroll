# frozen_string_literal: true

class CompanyAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :user_id, uniqueness: { scope: :company_id }
  validate :company_must_belong_to_user_organization

  private

  def company_must_belong_to_user_organization
    return if user.blank? || company.blank?
    return if user.organization_id.present? && user.organization_id == company.organization_id

    errors.add(:company, "must belong to the user's organization")
  end
end
