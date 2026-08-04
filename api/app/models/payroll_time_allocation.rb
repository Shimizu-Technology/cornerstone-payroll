# frozen_string_literal: true

class PayrollTimeAllocation < ApplicationRecord
  SOURCES = DailyTimeRecord::SOURCES
  LEDGER_KEYS = DailyTimeRecord::LEDGER_KEYS

  belongs_to :company
  belongs_to :employee
  belongs_to :payroll_item
  belongs_to :daily_time_record

  validates :work_date, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :ledger_key, inclusion: { in: LEDGER_KEYS }
  validates :scheduled_hours, :regular_hours, :overtime_hours, :pto_hours, :holiday_hours,
            numericality: { greater_than_or_equal_to: 0 }
  validate :relations_are_consistent

  private

  def relations_are_consistent
    errors.add(:company, "must match the payroll item") if payroll_item && payroll_item.company_id != company_id
    errors.add(:employee, "must match the payroll item") if payroll_item && payroll_item.employee_id != employee_id
    if daily_time_record && (daily_time_record.employee_id != employee_id || daily_time_record.work_date != work_date)
      errors.add(:daily_time_record, "must match the employee and work date")
    end
  end
end
