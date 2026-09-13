# frozen_string_literal: true

class ConnectPaymentsToPayrollLiabilities < ActiveRecord::Migration[8.1]
  ABANDONED_TABLES = %i[
    payroll_liability_allocations
    payroll_liability_due_dates
    payroll_liability_evidences
    payroll_liability_payments
  ].freeze

  def up
    # These tables leaked into schema.rb from an unmerged, abandoned branch and
    # have no migration on main. Removing them makes schema-load and migrated
    # environments converge before the supported settlement design is created.
    ABANDONED_TABLES.each { |table| drop_abandoned_table_if_empty(table) }

    add_column :non_employee_checks, :payment_method, :string, null: false, default: "check"
    add_column :non_employee_checks, :paid_at, :datetime
    add_reference :non_employee_checks, :paid_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_check_constraint :non_employee_checks,
                         "payment_method IN ('check', 'ach', 'eftps', 'wire', 'card', 'cash', 'other')",
                         name: "non_employee_checks_payment_method_check"
    add_check_constraint :non_employee_checks,
                         "paid_at IS NULL OR payment_date IS NOT NULL",
                         name: "non_employee_checks_paid_date_check"
    add_check_constraint :non_employee_checks,
                         "(paid_at IS NULL AND paid_by_id IS NULL) OR (paid_at IS NOT NULL AND paid_by_id IS NOT NULL)",
                         name: "non_employee_checks_paid_actor_check"
    add_check_constraint :non_employee_checks,
                         "paid_at IS NULL OR payment_method <> 'check' OR printed_at IS NOT NULL",
                         name: "non_employee_checks_paid_paper_printed_check"
    add_check_constraint :non_employee_checks,
                         "paid_at IS NULL OR payment_method NOT IN ('ach', 'eftps', 'wire', 'card') OR NULLIF(BTRIM(confirmation_number), '') IS NOT NULL",
                         name: "non_employee_checks_paid_electronic_confirmation_check"

    create_table :payroll_liability_check_allocations do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :non_employee_check, null: false, foreign_key: { on_delete: :cascade },
                   index: { name: "idx_liability_check_allocations_payment" }
      t.references :payroll_liability_entry, null: false, foreign_key: { on_delete: :restrict },
                   index: { name: "idx_liability_check_allocations_entry" }
      t.decimal :amount, precision: 14, scale: 2, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :payroll_liability_check_allocations,
              [ :non_employee_check_id, :payroll_liability_entry_id ],
              unique: true,
              name: "idx_liability_check_allocations_unique_entry"
    add_check_constraint :payroll_liability_check_allocations,
                         "amount > 0",
                         name: "liability_check_allocations_amount_positive"

    create_table :payroll_liability_obligation_due_dates do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :cascade }
      t.string :authority, null: false
      t.date :due_date, null: false
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :payroll_liability_obligation_due_dates,
              [ :pay_period_id, :authority ],
              unique: true,
              name: "idx_liability_obligation_due_dates_unique"
    add_index :payroll_liability_obligation_due_dates,
              [ :company_id, :due_date ],
              name: "idx_liability_obligation_due_dates_company_due"
  end

  def down
    drop_table :payroll_liability_obligation_due_dates
    drop_table :payroll_liability_check_allocations
    remove_check_constraint :non_employee_checks, name: "non_employee_checks_paid_electronic_confirmation_check"
    remove_check_constraint :non_employee_checks, name: "non_employee_checks_paid_paper_printed_check"
    remove_check_constraint :non_employee_checks, name: "non_employee_checks_paid_actor_check"
    remove_check_constraint :non_employee_checks, name: "non_employee_checks_paid_date_check"
    remove_check_constraint :non_employee_checks, name: "non_employee_checks_payment_method_check"
    remove_reference :non_employee_checks, :paid_by
    remove_column :non_employee_checks, :paid_at
    remove_column :non_employee_checks, :payment_method
  end

  private

  def drop_abandoned_table_if_empty(table)
    return unless table_exists?(table)

    quoted_table = connection.quote_table_name(table)
    if connection.select_value("SELECT EXISTS (SELECT 1 FROM #{quoted_table} LIMIT 1)")
      raise ActiveRecord::MigrationError,
            "Refusing to drop #{table}: the abandoned table contains data and needs a reviewed migration"
    end

    drop_table table
  end
end
