# frozen_string_literal: true

# A one-off contractor check can be linked to the contractor record it paid,
# so its amount joins that contractor's single 1099-NEC instead of standing
# alone without a TIN or address. The composite key keeps the link inside the
# check's own company; a linked contractor can't be deleted.
class AddPayeeEmployeeToNonEmployeeChecks < ActiveRecord::Migration[8.1]
  def change
    add_column :non_employee_checks, :payee_employee_id, :bigint
    add_index :non_employee_checks, %i[company_id payee_employee_id],
              where: "payee_employee_id IS NOT NULL", name: "idx_ne_checks_on_company_payee_employee"
    add_foreign_key :non_employee_checks, :employees,
                    column: %i[payee_employee_id company_id], primary_key: %i[id company_id],
                    name: "fk_ne_checks_payee_employee_same_company"
  end
end
