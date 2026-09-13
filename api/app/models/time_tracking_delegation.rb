# frozen_string_literal: true

class TimeTrackingDelegation < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :user

  encrypts :token

  validates :token, presence: true
  validates :user_id, uniqueness: { scope: :time_tracking_source_id }
  validate :records_belong_to_same_company
  validate :user_can_access_company
  validate :staff_user_is_active

  private

  def records_belong_to_same_company
    return if company.blank?

    errors.add(:time_tracking_source, "must belong to the same company") if time_tracking_source&.company_id != company_id
  end

  def user_can_access_company
    return if user.blank? || company.blank? || user.can_access_company?(company_id)

    errors.add(:user, "must have access to the company")
  end

  def staff_user_is_active
    return if user.blank?

    errors.add(:user, "must be an active staff member") unless user.active? && user.staff_member?
  end
end
