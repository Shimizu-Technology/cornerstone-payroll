# frozen_string_literal: true

class PinEmployeeStubWageLabels < ActiveRecord::Migration[8.1]
  def up
    add_column :employees, :legacy_stub_regular_wage_label, :string

    # The old renderer used the roster's current department on unitemized
    # wages. Preserve that input for employees with pre-existing stub history.
    execute "SET LOCAL app.rls_mode = 'system'"
    pin_existing_labels
  end

  def down
    remove_column :employees, :legacy_stub_regular_wage_label
  end

  private

  def pin_existing_labels
    execute <<~SQL
      UPDATE employees AS employee
      SET legacy_stub_regular_wage_label = department.name
      FROM departments AS department
      WHERE department.id = employee.department_id
        AND department.company_id = employee.company_id
        AND EXISTS (
          SELECT 1
          FROM payroll_items AS item
          JOIN employee_documents AS document
            ON document.payroll_item_id = item.id AND document.company_id = item.company_id
          WHERE item.company_id = employee.company_id
            AND item.employee_id = employee.id
        )
    SQL
  end
end
