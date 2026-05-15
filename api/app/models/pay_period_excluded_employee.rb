# frozen_string_literal: true

class PayPeriodExcludedEmployee < ApplicationRecord
  belongs_to :pay_period
  belongs_to :employee
  belongs_to :excluded_by, class_name: "User", optional: true

  validates :employee_id, uniqueness: { scope: :pay_period_id }
end
