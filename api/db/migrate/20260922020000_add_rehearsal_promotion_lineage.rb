# frozen_string_literal: true

class AddRehearsalPromotionLineage < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_reference :pay_periods,
                  :promotion_source_pay_period,
                  foreign_key: { to_table: :pay_periods, on_delete: :restrict },
                  index: false
    add_index :pay_periods,
              :promotion_source_pay_period_id,
              where: "promotion_source_pay_period_id IS NOT NULL",
              algorithm: :concurrently,
              name: "idx_pay_periods_promotion_source"
    add_index :pay_periods,
              [ :company_id, :promotion_source_pay_period_id ],
              unique: true,
              where: "promotion_source_pay_period_id IS NOT NULL",
              algorithm: :concurrently,
              name: "idx_pay_periods_promotion_source_unique"
  end
end
