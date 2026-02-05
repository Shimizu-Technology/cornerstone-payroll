# frozen_string_literal: true

class CreateCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :zip
      t.string :phone
      t.string :email
      t.string :ein # Employer Identification Number
      t.string :pay_frequency, default: "biweekly" # biweekly, weekly, semimonthly, monthly
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :companies, :name
    add_index :companies, :ein, unique: true
  end
end
