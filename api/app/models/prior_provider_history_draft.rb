# frozen_string_literal: true

class PriorProviderHistoryDraft < ApplicationRecord
  MAX_BYTES = 2.megabytes

  belongs_to :company
  belongs_to :updated_by, class_name: "User"

  validates :step, inclusion: { in: 0..3 }
  validate :payload_shape

  private

  def payload_shape
    errors.add(:payload, "must be an object") unless payload.is_a?(Hash)
    errors.add(:payload, "is too large to save") if payload.to_json.bytesize > MAX_BYTES
  end
end
