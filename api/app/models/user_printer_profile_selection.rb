# frozen_string_literal: true

class UserPrinterProfileSelection < ApplicationRecord
  belongs_to :user
  belongs_to :organization
  belongs_to :printer_profile

  validates :check_stock_type, inclusion: { in: Company::CHECK_STOCK_TYPES }
  validates :check_stock_type, uniqueness: { scope: [ :organization_id, :user_id ] }
  validate :profile_belongs_to_organization
  validate :profile_matches_stock_type
  validate :user_belongs_to_organization
  validate :profile_is_available

  private

  def profile_belongs_to_organization
    return if printer_profile.blank? || organization.blank?
    return if printer_profile.organization_id == organization_id

    errors.add(:printer_profile, "must belong to the selected organization")
  end

  def profile_matches_stock_type
    return if printer_profile.blank? || check_stock_type.blank?
    return if printer_profile.check_stock_type == check_stock_type

    errors.add(:printer_profile, "must match the selected check stock")
  end

  def user_belongs_to_organization
    return if user.blank? || organization.blank?
    return if user.super_admin? || user.organization_id == organization_id

    errors.add(:user, "must belong to the selected organization")
  end

  def profile_is_available
    return if printer_profile.blank? || !printer_profile.archived?

    errors.add(:printer_profile, "is archived")
  end
end
