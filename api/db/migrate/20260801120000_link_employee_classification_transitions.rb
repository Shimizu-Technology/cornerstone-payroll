# frozen_string_literal: true

class LinkEmployeeClassificationTransitions < ActiveRecord::Migration[8.1]
  def change
    add_reference :employees,
                  :previous_employee,
                  null: true,
                  foreign_key: { to_table: :employees },
                  index: { unique: true }
  end
end
