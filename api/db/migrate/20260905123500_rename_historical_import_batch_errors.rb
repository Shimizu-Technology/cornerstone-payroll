# frozen_string_literal: true

class RenameHistoricalImportBatchErrors < ActiveRecord::Migration[8.1]
  def change
    rename_column :historical_import_batches, :errors, :validation_errors
  end
end
