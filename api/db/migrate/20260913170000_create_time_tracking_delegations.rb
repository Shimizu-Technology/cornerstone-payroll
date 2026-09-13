# frozen_string_literal: true

class CreateTimeTrackingDelegations < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_delegations do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :time_tracking_source, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.text :token, null: false
      t.timestamps
    end

    add_index :time_tracking_delegations,
              [ :time_tracking_source_id, :user_id ],
              unique: true,
              name: "idx_time_tracking_delegations_source_user"
    add_index :time_tracking_delegations,
              [ :id, :company_id ],
              unique: true,
              name: "idx_time_tracking_delegations_tenant_key"
    add_foreign_key :time_tracking_delegations,
                    :time_tracking_sources,
                    column: [ :time_tracking_source_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_time_tracking_delegations_source_tenant",
                    on_delete: :cascade
  end
end
