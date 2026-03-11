# frozen_string_literal: true

# CPR-71: Add DB-level FK constraints for correction workflow integrity.
class AddCorrectionForeignKeys < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :pay_periods, :users,
      column: :voided_by_id,
      on_delete: :nullify unless foreign_key_exists?(:pay_periods, :users, column: :voided_by_id)

    add_foreign_key :pay_periods, :pay_periods,
      column: :source_pay_period_id,
      on_delete: :nullify unless foreign_key_exists?(:pay_periods, :pay_periods, column: :source_pay_period_id)

    add_foreign_key :pay_periods, :pay_periods,
      column: :superseded_by_id,
      on_delete: :nullify unless foreign_key_exists?(:pay_periods, :pay_periods, column: :superseded_by_id)

    add_foreign_key :pay_period_correction_events, :pay_periods,
      column: :pay_period_id,
      on_delete: :restrict unless foreign_key_exists?(:pay_period_correction_events, :pay_periods, column: :pay_period_id)

    add_foreign_key :pay_period_correction_events, :pay_periods,
      column: :resulting_pay_period_id,
      on_delete: :nullify unless foreign_key_exists?(:pay_period_correction_events, :pay_periods, column: :resulting_pay_period_id)

    add_foreign_key :pay_period_correction_events, :users,
      column: :actor_id,
      on_delete: :nullify unless foreign_key_exists?(:pay_period_correction_events, :users, column: :actor_id)

    add_foreign_key :pay_period_correction_events, :companies,
      column: :company_id,
      on_delete: :restrict unless foreign_key_exists?(:pay_period_correction_events, :companies, column: :company_id)
  end
end
