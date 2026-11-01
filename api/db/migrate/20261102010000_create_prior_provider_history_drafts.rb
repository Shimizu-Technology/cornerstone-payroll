# frozen_string_literal: true

# One shared, resumable work-in-progress per client. It holds operator-entered
# register values only; nothing is financial until conversion.
class CreatePriorProviderHistoryDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :prior_provider_history_drafts do |t|
      t.references :company, null: false, foreign_key: true, index: { unique: true }
      t.references :updated_by, null: false, foreign_key: { to_table: :users }
      t.jsonb :payload, null: false, default: {}
      t.integer :step, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :prior_provider_history_drafts, "step BETWEEN 0 AND 3", name: "prior_provider_draft_step"
  end
end
