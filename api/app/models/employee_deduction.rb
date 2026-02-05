# frozen_string_literal: true

class EmployeeDeduction < ApplicationRecord
  belongs_to :employee
  belongs_to :deduction_type

  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :deduction_type_id, uniqueness: { scope: :employee_id }

  scope :active, -> { where(active: true) }

  delegate :name, :category, :pre_tax?, :post_tax?, to: :deduction_type

  # Calculate the actual deduction amount for a given gross pay
  def calculate_amount(gross_pay)
    if is_percentage?
      (gross_pay * (amount / 100.0)).round(2)
    else
      amount
    end
  end
end
