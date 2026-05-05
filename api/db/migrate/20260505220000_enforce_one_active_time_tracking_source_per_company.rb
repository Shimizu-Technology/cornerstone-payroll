# frozen_string_literal: true

class EnforceOneActiveTimeTrackingSourcePerCompany < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      WITH ranked_sources AS (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY updated_at DESC, id DESC) AS row_number
        FROM time_tracking_sources
        WHERE active = TRUE
      )
      UPDATE time_tracking_sources
      SET active = FALSE,
          updated_at = CURRENT_TIMESTAMP
      WHERE id IN (
        SELECT id
        FROM ranked_sources
        WHERE row_number > 1
      )
    SQL

    add_index :time_tracking_sources,
      :company_id,
      unique: true,
      where: "active = TRUE",
      name: "index_time_tracking_sources_one_active_per_company"
  end

  def down
    remove_index :time_tracking_sources, name: "index_time_tracking_sources_one_active_per_company"
  end
end
