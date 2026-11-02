# frozen_string_literal: true

class TimeTrackingLockRolloutSelection < ApplicationRecord
  belongs_to :time_tracking_source

  validates :starts_on, :actor, presence: true
  validates :reason, length: { minimum: 10 }

  def readonly?
    persisted?
  end
end
