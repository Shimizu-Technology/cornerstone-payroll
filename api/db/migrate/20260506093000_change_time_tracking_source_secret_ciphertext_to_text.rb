# frozen_string_literal: true

class ChangeTimeTrackingSourceSecretCiphertextToText < ActiveRecord::Migration[8.1]
  def up
    change_column :time_tracking_sources, :shared_secret_ciphertext, :text
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Encrypted time tracking source secrets may exceed varchar(255); do not shrink this column back to string."
  end
end
