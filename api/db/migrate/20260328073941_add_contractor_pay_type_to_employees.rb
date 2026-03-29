class AddContractorPayTypeToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :contractor_pay_type, :string, default: "flat_fee"
  end
end
