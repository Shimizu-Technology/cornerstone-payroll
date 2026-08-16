# frozen_string_literal: true

class AddSalaryCompensationBasisToWorkProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_work_profiles, :salary_covers_weekly_hours, :decimal, precision: 6, scale: 2
    add_check_constraint :employee_work_profiles,
                         "salary_covers_weekly_hours IS NULL OR " \
                         "(salary_covers_weekly_hours >= 40 AND salary_covers_weekly_hours <= 168)",
                         name: "employee_work_profiles_salary_coverage_check"
  end
end
