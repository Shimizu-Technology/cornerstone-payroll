# frozen_string_literal: true

class AddSalaryCoverageReasonToWorkProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :employee_work_profiles, :salary_coverage_reason, :text
    add_check_constraint :employee_work_profiles,
                         "pay_basis <> 'salary' OR overtime_status <> 'nonexempt' OR " \
                         "(salary_covers_weekly_hours IS NOT NULL AND salary_coverage_reason IS NOT NULL)",
                         name: "employee_work_profiles_nonexempt_basis_check",
                         validate: false
  end
end
