# frozen_string_literal: true

class BindW2ReadinessToCurrentInputs < ActiveRecord::Migration[8.1]
  def up
    add_column :w2_filing_readinesses, :preflight_fingerprint, :string
    add_column :w2_filing_readinesses, :ready_fingerprint, :string
    add_column :w2_filing_readinesses, :attestation_history, :jsonb, default: [], null: false
    # Legacy attestations remain evidence, but have no verified source binding.
    execute <<~SQL
      UPDATE w2_filing_readinesses
      SET attestation_history = jsonb_build_array(jsonb_build_object(
        'marked_ready_at', marked_ready_at AT TIME ZONE 'UTC', 'marked_ready_by_id', marked_ready_by_id,
        'notes', notes, 'source_fingerprint', NULL, 'legacy', true))
      WHERE marked_ready_at IS NOT NULL
    SQL
  end

  def down
    remove_column :w2_filing_readinesses, :attestation_history
    remove_column :w2_filing_readinesses, :ready_fingerprint
    remove_column :w2_filing_readinesses, :preflight_fingerprint
  end
end
