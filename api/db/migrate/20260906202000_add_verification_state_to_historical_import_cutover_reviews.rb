# frozen_string_literal: true

class AddVerificationStateToHistoricalImportCutoverReviews < ActiveRecord::Migration[8.1]
  def change
    change_table :historical_import_cutover_reviews, bulk: true do |t|
      t.datetime :verification_started_at
      t.text :verification_error
    end
  end
end
