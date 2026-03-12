# frozen_string_literal: true

# CPR-71: Remove redundant non-unique indexes replaced by partial unique indexes.
class RemoveRedundantCorrectionIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :pay_periods, name: "index_pay_periods_on_source_pay_period_id" if index_exists?(:pay_periods, name: "index_pay_periods_on_source_pay_period_id")
    remove_index :pay_periods, name: "index_pay_periods_on_superseded_by_id" if index_exists?(:pay_periods, name: "index_pay_periods_on_superseded_by_id")
  end
end
