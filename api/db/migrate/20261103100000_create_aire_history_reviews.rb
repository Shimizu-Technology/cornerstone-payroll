# frozen_string_literal: true

class CreateAireHistoryReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :aire_history_reviews do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.references :receipt, foreign_key: { to_table: :aire_verified_history_rollout_receipts }
      t.string :digest, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.jsonb :summary, null: false, default: {}
      t.jsonb :approved_packet
      t.text :attestation
      t.datetime :approved_at
      t.timestamps
    end
    add_check_constraint :aire_history_reviews,
      "(approved_at IS NULL AND receipt_id IS NULL AND attestation IS NULL AND approved_packet IS NULL) OR " \
      "(approved_at IS NOT NULL AND receipt_id IS NOT NULL AND attestation IS NOT NULL AND approved_packet IS NOT NULL)",
      name: "aire_history_review_approval_shape"

    create_table :time_tracking_earning_choices do |t|
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :employee_wage_rate, null: false, foreign_key: true
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.string :source_category_key, null: false
      t.jsonb :rate_snapshot, null: false
      t.timestamps
    end
    add_index :time_tracking_earning_choices, [ :time_tracking_source_id, :employee_id, :source_category_key ], unique: true,
      name: "idx_time_earning_choice_dimension"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION protect_aire_history_review() RETURNS trigger AS $$
          BEGIN
            IF OLD.approved_at IS NOT NULL THEN
              RAISE EXCEPTION 'Approved AIRE history reviews are immutable';
            END IF;
            IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER aire_history_review_integrity BEFORE UPDATE OR DELETE ON aire_history_reviews
          FOR EACH ROW EXECUTE FUNCTION protect_aire_history_review();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS aire_history_review_integrity ON aire_history_reviews"
        execute "DROP FUNCTION IF EXISTS protect_aire_history_review()"
      end
    end
  end
end
