# frozen_string_literal: true

class PayrollImportRecord < ApplicationRecord
  self.table_name = "payroll_imports"

  belongs_to :pay_period
  belongs_to :payroll_intake_session, optional: true
  has_many :submission_imports, class_name: "PayrollSubmissionImport", foreign_key: :payroll_import_id, dependent: :restrict_with_error
  has_many :payroll_submissions, through: :submission_imports

  validates :status, inclusion: { in: %w[pending previewed applied partially_applied failed] }

  scope :for_pay_period, ->(pay_period_id) { where(pay_period_id: pay_period_id) }
end
