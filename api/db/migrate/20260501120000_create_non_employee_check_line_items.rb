class CreateNonEmployeeCheckLineItems < ActiveRecord::Migration[8.0]
  def change
    create_table :non_employee_check_line_items do |t|
      t.references :non_employee_check, null: false, foreign_key: { on_delete: :cascade }, index: { name: "idx_ne_check_line_items_on_check" }
      t.string :description, null: false
      t.string :reference_number
      t.string :service_period
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :non_employee_check_line_items,
      [ :non_employee_check_id, :position ],
      name: "idx_ne_check_line_items_on_check_position"

    add_check_constraint :non_employee_check_line_items,
      "amount > 0",
      name: "non_employee_check_line_items_amount_positive"
  end
end
