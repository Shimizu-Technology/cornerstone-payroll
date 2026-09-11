# frozen_string_literal: true

class AddW4SourceProvenance < ActiveRecord::Migration[8.0]
  def change
    %i[employees employee_w4_elections].each do |table|
      add_column table, :w4_signed_on, :date
      add_column table, :w4_source_reference, :string
    end
  end
end
