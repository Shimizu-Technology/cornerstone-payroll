# frozen_string_literal: true

# An employee's explicit "keep paper" answer for one delivery kind. It never
# turns paper on or off; it only records that the employee answered.
class DeliveryPreference < ApplicationRecord
  KINDS = DeliveryDisclosure::KINDS
  CHOICES = %w[keep_paper].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :employee_account_link
  belongs_to :user

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :choice, presence: true, inclusion: { in: CHOICES }
  validates :recorded_at, presence: true
  validate :associations_match_company_and_employee

  private

  def associations_match_company_and_employee
    if employee && employee.company_id != company_id
      errors.add(:employee, "must belong to the preference company")
    end
    if employee_account_link && (employee_account_link.company_id != company_id || employee_account_link.employee_id != employee_id)
      errors.add(:employee_account_link, "must belong to the preference employee and company")
    end
  end
end
