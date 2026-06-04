# frozen_string_literal: true

class RemoveTransmittalPayrollCheckNumbersDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :transmittals, :payroll_check_numbers, from: [], to: nil
  end
end
