# frozen_string_literal: true

class EmployeeConfigurationReviewResolution < ApplicationRecord
  CERTIFICATION_ITEM_CODES = %w[
    certify_employee_profile certify_variable_salary_pay certify_retirement_configuration
    certify_multiple_wage_rates certify_tipped_pay certify_contractor_setup
    loan_balance_not_transferred
  ].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :item_code, :item_message, :resolution_note,
            :reviewed_by_name, :reviewed_by_email, :reviewed_by_role, :reviewed_at,
            presence: true
  validates :item_code, uniqueness: { scope: :employee_id }
  validates :source_reference, length: { maximum: 255 }, allow_nil: true
  validates :source_reference, :effective_on, presence: true, if: :certification_item?
  validate :employee_belongs_to_company
  validate :item_fields_are_strings

  before_update :prevent_change
  before_destroy :prevent_change

  private

  def employee_belongs_to_company
    return if employee.blank? || employee.company_id == company_id

    errors.add(:employee, "must belong to the reviewed company")
  end

  def item_fields_are_strings
    return if item_fields.is_a?(Array) && item_fields.all? { |value| value.is_a?(String) }

    errors.add(:item_fields, "must be a list of field names")
  end

  def prevent_change
    errors.add(:base, "Employee setup review resolutions are permanent")
    throw(:abort)
  end

  def certification_item?
    CERTIFICATION_ITEM_CODES.include?(item_code)
  end
end
