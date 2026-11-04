# frozen_string_literal: true

class AireHistoryReview < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :actor, class_name: "User"
  belongs_to :receipt, class_name: "AireVerifiedHistoryRolloutReceipt", optional: true

  validates :digest, format: { with: /\A[0-9a-f]{64}\z/ }

  def readonly?
    persisted? && approved_at_in_database.present?
  end
end
