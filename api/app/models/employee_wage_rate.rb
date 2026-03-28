# frozen_string_literal: true

class EmployeeWageRate < ApplicationRecord
  belongs_to :employee

  validates :label, presence: true
  validates :label, uniqueness: { scope: :employee_id }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :primary, -> { where(is_primary: true) }
end
