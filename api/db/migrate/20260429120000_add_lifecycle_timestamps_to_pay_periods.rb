# frozen_string_literal: true

class AddLifecycleTimestampsToPayPeriods < ActiveRecord::Migration[7.1]
  def change
    add_column :pay_periods, :calculated_at, :datetime
    add_column :pay_periods, :calculated_by_id, :bigint
    add_column :pay_periods, :approved_at, :datetime
    add_column :pay_periods, :unapproved_at, :datetime
    add_column :pay_periods, :unapproved_by_id, :bigint
    add_column :pay_periods, :committed_by_id, :bigint

    add_index :pay_periods, :calculated_by_id
    add_index :pay_periods, :unapproved_by_id
    add_index :pay_periods, :committed_by_id
  end
end
