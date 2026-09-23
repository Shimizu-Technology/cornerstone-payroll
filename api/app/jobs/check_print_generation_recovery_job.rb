# frozen_string_literal: true

class CheckPrintGenerationRecoveryJob < ApplicationJob
  queue_as :default

  ABANDONED_AFTER = 30.minutes

  def perform
    cutoff = ABANDONED_AFTER.ago
    CheckPrintGeneration.active.where(updated_at: ...cutoff).find_each do |generation|
      generation.recover_if_abandoned!(cutoff: cutoff)
    end
  end
end
