class CreateTransmittals < ActiveRecord::Migration[8.1]
  def change
    create_table :transmittals do |t|
      t.references :pay_period, null: false, foreign_key: true, index: { unique: true }
      t.references :company, null: false, foreign_key: true
      t.string :preparer_name
      t.jsonb :notes, default: []
      t.jsonb :report_list, default: []
      t.string :check_number_first
      t.string :check_number_last
      t.jsonb :non_employee_check_numbers, default: {}
      t.datetime :generated_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end
  end
end
