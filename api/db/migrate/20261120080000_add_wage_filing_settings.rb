# frozen_string_literal: true

class AddWageFilingSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :filing_submitters do |t|
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      %i[ein name address_line1 address_line2 city state zip contact_name contact_phone contact_email bso_user_id].each { |field| t.string field }
      t.timestamps
    end
    add_column :companies, :filing_contact_name, :string
    add_column :companies, :kind_of_employer, :string, null: false, default: "N"
    add_column :companies, :employment_code, :string, null: false, default: "R"
    add_column :companies, :establishment_number, :string
    add_column :employees, :name_suffix, :string
  end
end
