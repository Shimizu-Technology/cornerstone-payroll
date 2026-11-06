# frozen_string_literal: true

class AddTimeTrackingCutoffPolicyToPaySchedules < ActiveRecord::Migration[8.1]
  def change
    add_column :company_pay_schedules, :time_tracking_cutoff_rule, :string,
               null: false, default: "before_pay_date"
    add_column :company_pay_schedules, :time_tracking_cutoff_days, :integer,
               null: false, default: 7
    add_check_constraint :company_pay_schedules,
                         "time_tracking_cutoff_rule IN ('before_pay_date', 'after_previous_regular_payday')",
                         name: "company_pay_schedules_time_cutoff_rule_check"
    add_check_constraint :company_pay_schedules,
                         "time_tracking_cutoff_days BETWEEN 0 AND 31",
                         name: "company_pay_schedules_time_cutoff_days_check"
  end
end
