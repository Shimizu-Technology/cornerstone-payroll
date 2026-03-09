# frozen_string_literal: true

class CreatePayrollImports < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_imports do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.string :status, default: "pending", null: false
      t.string :pdf_filename
      t.string :excel_filename
      t.jsonb :raw_data, default: {}
      t.jsonb :matched_data, default: {}
      t.jsonb :unmatched_pdf_names, default: []
      t.jsonb :validation_errors, default: []

      t.timestamps
    end

    add_index :payroll_imports, [:pay_period_id, :status]
  end
end
