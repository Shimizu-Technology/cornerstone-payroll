# frozen_string_literal: true

class AddJobTitleToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :job_title, :string
  end
end
