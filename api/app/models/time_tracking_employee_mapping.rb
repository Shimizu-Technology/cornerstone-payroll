# frozen_string_literal: true

class TimeTrackingEmployeeMapping < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :employee

  validates :source_user_id, presence: true
  validates :source_user_id, uniqueness: { scope: [ :company_id, :time_tracking_source_id ] }
  validate :employee_belongs_to_company

  private

  def employee_belongs_to_company
    return if employee.nil? || employee.company_id == company_id

    errors.add(:employee, "must belong to the same company")
  end
end
