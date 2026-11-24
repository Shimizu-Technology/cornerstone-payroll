# frozen_string_literal: true

class AddProfileAddressRequestOrigin < ActiveRecord::Migration[8.1]
  def change
    add_reference :employee_change_requests, :requested_by_link
    add_column :employee_change_requests, :own_record, :boolean, null: false, default: false

    add_index :employee_account_links, %i[id employee_id company_id], unique: true, name: "idx_employee_account_links_employee_key"
    add_foreign_key :employee_change_requests, :employee_account_links,
      column: %i[requested_by_link_id employee_id company_id], primary_key: %i[id employee_id company_id],
      name: "fk_employee_change_requests_requester_link"
  end
end
