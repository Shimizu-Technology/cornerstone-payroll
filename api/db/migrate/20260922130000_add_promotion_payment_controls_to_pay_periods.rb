class AddPromotionPaymentControlsToPayPeriods < ActiveRecord::Migration[8.1]
  def up
    add_column :pay_periods, :promotion_payment_disposition, :string
    add_column :pay_periods, :promoted_payment_prepared_at, :datetime
    add_reference :pay_periods,
                  :promoted_payment_prepared_by,
                  foreign_key: { to_table: :users },
                  index: true

    execute <<~SQL.squish
      UPDATE pay_periods
      SET promotion_payment_disposition = 'record_only'
      WHERE promotion_source_pay_period_id IS NOT NULL
    SQL

    add_check_constraint :pay_periods,
                         <<~SQL.squish,
                           (
                             promotion_source_pay_period_id IS NULL AND promotion_payment_disposition IS NULL
                           ) OR (
                             promotion_source_pay_period_id IS NOT NULL AND
                             promotion_payment_disposition IN ('record_only', 'process_in_cornerstone')
                           )
                         SQL
                         name: "pay_periods_promotion_payment_disposition_complete"
    add_check_constraint :pay_periods,
                         "(promoted_payment_prepared_at IS NULL) = (promoted_payment_prepared_by_id IS NULL)",
                         name: "pay_periods_promoted_payment_preparer_complete"
    add_check_constraint :pay_periods,
                         "promoted_payment_prepared_at IS NULL OR promotion_payment_disposition = 'process_in_cornerstone'",
                         name: "pay_periods_promoted_payment_prepared_disposition"
  end

  def down
    remove_check_constraint :pay_periods, name: "pay_periods_promoted_payment_prepared_disposition"
    remove_check_constraint :pay_periods, name: "pay_periods_promoted_payment_preparer_complete"
    remove_check_constraint :pay_periods, name: "pay_periods_promotion_payment_disposition_complete"
    remove_reference :pay_periods, :promoted_payment_prepared_by, foreign_key: { to_table: :users }
    remove_column :pay_periods, :promoted_payment_prepared_at
    remove_column :pay_periods, :promotion_payment_disposition
  end
end
