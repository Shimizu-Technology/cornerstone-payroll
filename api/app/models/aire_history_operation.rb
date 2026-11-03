# frozen_string_literal: true

class AireHistoryOperation < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :actor, class_name: "User"

  def response_payload
    { operation_id: id, status: status, result: result, error: error, changes: source_changes }
  end
end
