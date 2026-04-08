# frozen_string_literal: true

class AddUniqueFitCheckIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :non_employee_checks,
              [:pay_period_id, :company_id, :check_type, :payable_to],
              unique: true,
              where: "voided = false",
              name: "idx_unique_non_voided_ne_check_per_period"
  end
end
