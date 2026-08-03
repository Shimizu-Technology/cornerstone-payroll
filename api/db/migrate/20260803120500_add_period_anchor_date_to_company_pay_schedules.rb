# frozen_string_literal: true

class AddPeriodAnchorDateToCompanyPaySchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :company_pay_schedules, :period_anchor_date, :date
    add_check_constraint :company_pay_schedules,
                         "period_rule <> 'biweekly' OR period_anchor_date IS NOT NULL",
                         name: "company_pay_schedules_biweekly_anchor_check"
    add_check_constraint :company_pay_schedules,
                         "period_anchor_date IS NULL OR period_start_weekday IS NULL OR " \
                         "EXTRACT(DOW FROM period_anchor_date)::integer = period_start_weekday",
                         name: "company_pay_schedules_anchor_weekday_check"
  end
end
