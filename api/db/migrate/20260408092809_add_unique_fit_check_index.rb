# frozen_string_literal: true

class AddUniqueFitCheckIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :non_employee_checks,
              [:pay_period_id, :company_id],
              unique: true,
              where: "check_type = 'tax_deposit' AND payable_to = 'EFTPS - Federal Income Tax' AND voided = false",
              name: "idx_unique_non_voided_fit_check_per_period"
  end
end
