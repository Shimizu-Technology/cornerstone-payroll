# frozen_string_literal: true

class PayPeriodVerificationAcknowledgement < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period
  belongs_to :employee_verification_item
  belongs_to :employee
  belongs_to :acknowledged_by, class_name: "User"

  validates :acknowledged_at, :item_updated_at_snapshot, presence: true
  validates :item_status_snapshot, inclusion: { in: EmployeeVerificationItem::OPEN_STATUSES }
  validates :employee_verification_item_id, uniqueness: { scope: :pay_period_id }
  validate :tenant_consistency

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def tenant_consistency
    if pay_period.present? && company_id != pay_period.company_id
      errors.add(:pay_period, "must belong to the same company")
    end
    if employee.present? && company_id != employee.company_id
      errors.add(:employee, "must belong to the same company")
    end
    if employee_verification_item.present?
      if company_id != employee_verification_item.company_id
        errors.add(:employee_verification_item, "must belong to the same company")
      end
      if employee_id.present? && employee_id != employee_verification_item.employee_id
        errors.add(:employee, "must match the verification item's employee")
      end
    end
  end

  def prevent_mutation
    errors.add(:base, "Pay period verification acknowledgements are immutable")
    throw :abort
  end
end
