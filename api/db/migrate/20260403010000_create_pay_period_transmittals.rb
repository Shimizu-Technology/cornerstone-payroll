# frozen_string_literal: true

class CreatePayPeriodTransmittals < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_period_transmittals do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true, index: { unique: true }
      t.string :preparer_name
      t.jsonb :notes, null: false, default: []
      t.jsonb :report_list, null: false, default: []
      t.string :check_number_first
      t.string :check_number_last
      t.jsonb :non_employee_check_numbers, null: false, default: {}

      t.timestamps
    end

    create_table :pay_period_transmittal_versions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.references :pay_period_transmittal, null: false, foreign_key: true
      t.references :generated_by, foreign_key: { to_table: :users }
      t.integer :version_number, null: false
      t.datetime :generated_at, null: false
      t.string :generated_from, null: false, default: "transmittal_log"
      t.string :preparer_name
      t.jsonb :notes, null: false, default: []
      t.jsonb :report_list, null: false, default: []
      t.string :check_number_first
      t.string :check_number_last
      t.jsonb :non_employee_check_numbers, null: false, default: {}

      t.timestamps
    end

    add_index :pay_period_transmittal_versions,
              [:pay_period_transmittal_id, :version_number],
              unique: true,
              name: "idx_pp_transmittal_versions_on_version"
    add_index :pay_period_transmittal_versions,
              [:pay_period_id, :generated_at],
              name: "idx_pp_transmittal_versions_on_generated_at"
  end
end
