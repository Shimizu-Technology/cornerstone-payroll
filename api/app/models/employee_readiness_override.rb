# frozen_string_literal: true

class EmployeeReadinessOverride < ApplicationRecord
  MIN_REASON_LENGTH = 10
  MAX_REASON_LENGTH = 1000

  belongs_to :company
  belongs_to :employee
  belongs_to :pay_period, optional: true
  belongs_to :default_w4_election, class_name: "EmployeeW4Election", optional: true
  belongs_to :granted_by, class_name: "User"
  belongs_to :revoked_by, class_name: "User", optional: true
  belongs_to :admin_override

  validates :granted_at, presence: true
  validates :default_w4_acknowledged, inclusion: { in: [ true, false ] }
  validate :reason_length_valid
  validate :scope_present
  validate :tenant_consistency

  scope :active, -> { where(revoked_at: nil) }

  def active_for_period?(pay_period)
    return false if revoked_at.present?
    return true if pay_period_id.present? && pay_period_id == pay_period.id
    return true if pay_period_id.nil? && expires_on.present? && pay_period.pay_date <= expires_on

    false
  end

  def covers_missing_keys?(missing_keys)
    (Array(missing_keys).map(&:to_s) - Array(missing_items_snapshot).map(&:to_s)).empty?
  end

  private

  def reason_length_valid
    trimmed = reason.to_s.strip
    return if trimmed.length.between?(MIN_REASON_LENGTH, MAX_REASON_LENGTH)

    errors.add(:reason, "must be between #{MIN_REASON_LENGTH} and #{MAX_REASON_LENGTH} characters")
  end

  def scope_present
    return if pay_period_id.present? || expires_on.present?

    errors.add(:base, "Specify either a pay period or an expiration date")
  end

  def tenant_consistency
    if employee.present? && company_id != employee.company_id
      errors.add(:employee, "must belong to the same company")
    end
    if pay_period.present? && company_id != pay_period.company_id
      errors.add(:pay_period, "must belong to the same company")
    end
    if default_w4_election.present? && company_id != default_w4_election.company_id
      errors.add(:default_w4_election, "must belong to the same company")
    end
    if admin_override.present? && company_id != admin_override.company_id
      errors.add(:admin_override, "must belong to the same company")
    end
  end
end
