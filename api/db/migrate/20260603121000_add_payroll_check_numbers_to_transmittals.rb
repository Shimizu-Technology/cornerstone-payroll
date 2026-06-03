class AddPayrollCheckNumbersToTransmittals < ActiveRecord::Migration[8.1]
  def change
    add_column :transmittals, :payroll_check_numbers, :jsonb, default: []
  end
end
