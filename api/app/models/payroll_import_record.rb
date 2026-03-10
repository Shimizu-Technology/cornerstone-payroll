# frozen_string_literal: true

class PayrollImportRecord < ApplicationRecord
  self.table_name = "payroll_imports"

  belongs_to :pay_period

  validates :status, inclusion: { in: %w[pending previewed applied partially_applied failed] }

  scope :for_pay_period, ->(pay_period_id) { where(pay_period_id: pay_period_id) }
end
