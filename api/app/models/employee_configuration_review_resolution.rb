# frozen_string_literal: true

class EmployeeConfigurationReviewResolution < ApplicationRecord
  belongs_to :company
  belongs_to :employee
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :item_code, :item_message, :resolution_note,
            :reviewed_by_name, :reviewed_by_email, :reviewed_by_role, :reviewed_at,
            presence: true
  validates :item_code, uniqueness: { scope: :employee_id }
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
end
