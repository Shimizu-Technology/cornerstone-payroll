# frozen_string_literal: true

# Source completeness only, never a historical basis proof or filing sign-off.
# New reviews supersede older reviews; no default "no external wages" assumption.
class EmployeeYearFicaSourceReview < ApplicationRecord
  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User"

  validates :tax_year, inclusion: { in: 2000..2200 }
  validates :through_pay_date, presence: true
  validates :review_reference, length: { minimum: 10, maximum: 1000 }
  validates :external_ss_wage_bound, :external_medicare_wage_bound, numericality: { greater_than_or_equal_to: 0 }
  validate do
    errors.add(:company, "must match employee") if employee && employee.company_id != company_id
    if through_pay_date && through_pay_date.year != tax_year
      errors.add(:through_pay_date, "must be in the tax year")
    end
    if external_ss_wage_bound && external_medicare_wage_bound && external_ss_wage_bound > external_medicare_wage_bound
      errors.add(:external_medicare_wage_bound, "must cover Social Security wages")
    end
  end
  before_update { raise ActiveRecord::ReadOnlyRecord, "FICA source reviews are append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "FICA source reviews are append-only" }

  def self.record!(employee:, actor:, **attributes)
    unless actor&.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(employee.company_id)
      raise ArgumentError, "An authorized payroll administrator is required"
    end
    transaction do
      Company.lock.find(employee.company_id)
      create!(**attributes, company_id: employee.company_id, employee: employee, created_by: actor)
    end
  end
end
