# frozen_string_literal: true

# How a company's paper W-2s reach its employees (M4-5, §8a): mailed to the
# home address, handed out at work, or not set. The employee app says
# "Your W-2 will be mailed here" only when it's mailed.
class AddW2DeliveryToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :w2_delivery, :string
    add_check_constraint :companies, "w2_delivery IS NULL OR w2_delivery IN ('mailed', 'handed_out')",
      name: "companies_w2_delivery_check"
  end
end
