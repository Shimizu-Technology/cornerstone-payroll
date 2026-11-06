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
    record_batch!(company_id: employee.company_id, employee_ids: [ employee.id ], actor: actor, **attributes).first
  end

  # Resolve and validate the complete batch under the same lock used by payroll.
  # Preview follows the same authorization and validation path without inserting.
  def self.record_batch!(company_id:, employee_ids:, actor:, apply: true, **attributes)
    authorize_actor!(actor, company_id)
    transaction do
      Company.lock.find(company_id)
      actor = User.lock.find_by(id: actor&.id)
      authorize_actor!(actor, company_id)
      employees = employee_ids.uniq.map { |id| Employee.where(company_id: company_id).find(id) }
      raise ArgumentError, "At least one employee is required" if employees.empty?
      reviews = employees.map do |employee|
        new(**attributes, company_id: company_id, employee: employee, created_by: actor).tap(&:validate!)
      end
      reviews.each(&:save!) if apply
      reviews
    end
  end

  def self.authorize_actor!(actor, company_id)
    unless actor&.payroll_access_allowed? && actor.organization_admin? && actor.can_access_company?(company_id)
      raise ArgumentError, "An authorized payroll administrator is required"
    end
  end
  private_class_method :authorize_actor!
end
