# frozen_string_literal: true

class AddTccToFilingSubmitters < ActiveRecord::Migration[8.1]
  def change
    add_column :filing_submitters, :tcc, :string, limit: 5
  end
end
