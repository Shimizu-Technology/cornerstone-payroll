# frozen_string_literal: true

class PrepareChecksWhenPackageIsGenerated < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :check_prepared_at, :datetime
    add_column :payroll_items, :check_prepared_source_updated_at, :datetime
    add_column :non_employee_checks, :prepared_at, :datetime
    add_column :non_employee_checks, :prepared_source_updated_at, :datetime

    remove_check_constraint :check_print_runs, "status IN ('generated', 'confirmed')",
      name: "check_print_runs_status_check"
    add_check_constraint :check_print_runs, "status IN ('generated', 'prepared', 'confirmed')",
      name: "check_print_runs_status_check"

    remove_check_constraint :non_employee_checks,
      "paid_at IS NULL OR payment_method <> 'check' OR printed_at IS NOT NULL",
      name: "non_employee_checks_paid_paper_printed_check"
    add_check_constraint :non_employee_checks,
      "paid_at IS NULL OR payment_method <> 'check' OR printed_at IS NOT NULL OR prepared_at IS NOT NULL",
      name: "non_employee_checks_paid_paper_prepared_check"

    remove_column :companies, :require_distinct_check_print_confirmer, :boolean, default: false, null: false
  end
end
