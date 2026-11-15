# frozen_string_literal: true

class AddRecordCreators < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :companies, :created_by_id, :bigint
    add_column :employees, :created_by_id, :bigint
    add_index :companies, :created_by_id, algorithm: :concurrently
    add_index :employees, :created_by_id, algorithm: :concurrently
    add_index :pay_periods, :created_by_id, algorithm: :concurrently
  end
end
