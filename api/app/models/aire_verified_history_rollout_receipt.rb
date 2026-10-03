# frozen_string_literal: true

class AireVerifiedHistoryRolloutReceipt < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source

  validates :manifest_sha256, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-f]{64}\z/ }
  validates :identity_count, :paid_source_entry_count,
            numericality: { only_integer: true, greater_than: 0 }
  validates :completed_at, presence: true
end
