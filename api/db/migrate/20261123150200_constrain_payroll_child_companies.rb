# frozen_string_literal: true

require_relative "support/m3_7_child_companies"

class ConstrainPayrollChildCompanies < ActiveRecord::Migration[8.1]
  include M3_7ChildCompanies
  disable_ddl_transaction!

  ON_DELETE = {
    employee_tipped_occupations: :cascade,
    general_transmittal_items: :cascade,
    non_employee_check_edits: :cascade,
    non_employee_check_line_items: :cascade,
    time_tracking_financial_correction_links: :restrict
  }.freeze

  def up
    CHILDREN.each do |table, (key, parent)|
      with_short_ddl_transaction do
        add_foreign_key table, parent, column: [ key, :company_id ], primary_key: %i[id company_id],
          name: M3_7ChildCompanies.foreign_key_name(table), on_delete: ON_DELETE[table], validate: false, if_not_exists: true
      end
    end
  end

  def down
    CHILDREN.each_key do |table|
      with_short_ddl_transaction do
        remove_foreign_key table, name: M3_7ChildCompanies.foreign_key_name(table), if_exists: true
      end
    end
  end
end
