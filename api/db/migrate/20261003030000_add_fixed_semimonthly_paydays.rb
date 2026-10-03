# frozen_string_literal: true

class AddFixedSemimonthlyPaydays < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :company_pay_schedules, name: "company_pay_schedules_pay_date_rule_check"
    add_check_constraint :company_pay_schedules,
      "pay_date_rule IN ('manual', 'days_after_period_end', 'semimonthly_15th_and_month_end')",
      name: "company_pay_schedules_pay_date_rule_check"
    add_check_constraint :company_pay_schedules,
      "pay_date_rule != 'semimonthly_15th_and_month_end' OR (frequency = 'semimonthly' AND period_rule = 'semimonthly')",
      name: "company_pay_schedules_fixed_semimonthly_check"
  end

  def down
    if select_value("SELECT COUNT(*) FROM company_pay_schedules WHERE pay_date_rule = 'semimonthly_15th_and_month_end'").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Explicitly review fixed semimonthly schedules before removing this rule"
    end
    remove_check_constraint :company_pay_schedules, name: "company_pay_schedules_fixed_semimonthly_check"
    remove_check_constraint :company_pay_schedules, name: "company_pay_schedules_pay_date_rule_check"
    add_check_constraint :company_pay_schedules, "pay_date_rule IN ('manual', 'days_after_period_end')",
      name: "company_pay_schedules_pay_date_rule_check"
  end
end
