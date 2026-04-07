# frozen_string_literal: true

class PayrollReminderLog < ApplicationRecord
  REMINDER_TYPES = %w[upcoming overdue create_payroll].freeze

  belongs_to :company
  belongs_to :pay_period, optional: true

  validates :reminder_type, inclusion: { in: REMINDER_TYPES }
  validates :sent_at, presence: true
  validates :pay_period_id, uniqueness: { scope: [:company_id, :reminder_type] }, if: -> { pay_period_id.present? }
  validates :expected_pay_date, uniqueness: { scope: [:company_id, :reminder_type] }, if: -> { pay_period_id.nil? && expected_pay_date.present? }
end
