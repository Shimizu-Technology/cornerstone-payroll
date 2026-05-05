# frozen_string_literal: true

class RenameTimeTrackingSourceSecretColumn < ActiveRecord::Migration[8.1]
  def change
    rename_column :time_tracking_sources, :shared_secret_ciphertext, :shared_secret
  end
end
