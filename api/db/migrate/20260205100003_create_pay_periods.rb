# frozen_string_literal: true

class CreatePayPeriods < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_periods do |t|
      t.references :company, null: false, foreign_key: true
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.date :pay_date, null: false
      t.string :status, default: "draft" # draft, calculated, approved, committed
      t.bigint :created_by_id
      t.bigint :approved_by_id
      t.datetime :committed_at
      t.text :notes

      t.timestamps
    end

    add_index :pay_periods, [ :company_id, :start_date ]
    add_index :pay_periods, [ :company_id, :end_date ]
    add_index :pay_periods, :status
    add_index :pay_periods, [ :company_id, :status ]
  end
end
