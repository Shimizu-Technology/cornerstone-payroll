class AddTransmittalDateToTransmittals < ActiveRecord::Migration[8.1]
  def change
    add_column :transmittals, :transmittal_date, :date
  end
end
