# frozen_string_literal: true

class QueueDurabilityProbeJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5

  def perform(probe_id)
    probe = OperationalQueueProbe.find_by!(probe_id: probe_id.to_s.downcase)

    probe.with_lock do
      probe.attempt_count += 1
      if probe.effect_count.zero?
        probe.effect_count = 1
        probe.completed_at = Time.current
      end
      probe.save!
    end
  end
end
