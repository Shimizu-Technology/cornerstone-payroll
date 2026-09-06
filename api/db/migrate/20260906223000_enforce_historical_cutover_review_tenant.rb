# frozen_string_literal: true

class EnforceHistoricalCutoverReviewTenant < ActiveRecord::Migration[8.1]
  def change
    add_index :historical_import_batches, %i[id company_id],
              unique: true,
              name: "idx_historical_import_batches_tenant_key"
    add_foreign_key :historical_import_cutover_reviews,
                    :historical_import_batches,
                    column: %i[historical_import_batch_id company_id],
                    primary_key: %i[id company_id],
                    name: "fk_historical_cutover_reviews_batch_tenant"
  end
end
