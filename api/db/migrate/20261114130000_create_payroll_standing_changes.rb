# frozen_string_literal: true

class CreatePayrollStandingChanges < ActiveRecord::Migration[8.1]
  def change
    reversible do |direction|
      direction.up do
        remove_check_constraint :payroll_submissions, name: "payroll_submissions_no_changes_is_empty"
        add_check_constraint :payroll_submissions,
          "NOT no_changes OR jsonb_array_length(jsonb_path_query_array(change_rows, '$[*] ? (@.skipped == true)')) = jsonb_array_length(change_rows)",
          name: "payroll_submissions_no_changes_is_empty"
      end
      direction.down do
        remove_check_constraint :payroll_submissions, name: "payroll_submissions_no_changes_is_empty"
        add_check_constraint :payroll_submissions, "NOT no_changes OR change_rows = '[]'::jsonb", name: "payroll_submissions_no_changes_is_empty"
      end
    end

    create_table :payroll_standing_changes do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :employee_wage_rate, foreign_key: { on_delete: :nullify }
      t.string :kind, null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :payroll_standing_changes, "kind IN ('owner_pay', 'extra_hours')", name: "standing_change_kind"
    add_check_constraint :payroll_standing_changes, "position >= 0", name: "standing_change_position"
  end
end
