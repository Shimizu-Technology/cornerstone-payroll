# frozen_string_literal: true

require "securerandom"

module QueueDurabilityProbeTasks
  module_function

  def normalized_probe_id(value)
    raw = value.to_s
    abort "PROBE_ID must not contain line breaks" if raw.match?(/[\r\n]/)

    normalized = raw.strip.downcase
    abort "PROBE_ID must be a canonical UUID" unless normalized.match?(OperationalQueueProbe::UUID_PATTERN)

    normalized
  end

  def find_probe!
    probe_id = ENV["PROBE_ID"]
    abort "PROBE_ID is required" if probe_id.blank?

    OperationalQueueProbe.find_by!(probe_id: normalized_probe_id(probe_id))
  end
end

namespace :operations do
  namespace :queue_probe do
    desc "Enqueue a non-payroll durability probe (optional PROBE_ID, TTL_HOURS)"
    task enqueue: :environment do
      probe_id = QueueDurabilityProbeTasks.normalized_probe_id(ENV.fetch("PROBE_ID", SecureRandom.uuid))
      begin
        ttl_hours = Integer(ENV.fetch("TTL_HOURS", "24"), 10)
      rescue ArgumentError
        abort "TTL_HOURS must be between 1 and 168"
      end
      abort "TTL_HOURS must be between 1 and 168" unless ttl_hours.between?(1, 168)

      probe = OperationalQueueProbe.create!(probe_id: probe_id, expires_at: ttl_hours.hours.from_now)
      job = QueueDurabilityProbeJob.perform_later(probe.probe_id)
      puts JSON.generate(event: "queue_probe_enqueued", probe_id: probe.probe_id, job_id: job.job_id)
    end

    desc "Print the non-secret status of a durability probe (requires PROBE_ID)"
    task status: :environment do
      probe = QueueDurabilityProbeTasks.find_probe!
      puts JSON.generate(
        event: "queue_probe_status",
        probe_id: probe.probe_id,
        attempt_count: probe.attempt_count,
        effect_count: probe.effect_count,
        completed_at: probe.completed_at&.iso8601,
        expires_at: probe.expires_at.iso8601,
        passed: probe.passed?
      )
    end

    desc "Replay an existing durability probe without creating a second effect (requires PROBE_ID)"
    task replay: :environment do
      probe = QueueDurabilityProbeTasks.find_probe!
      abort "Probe must complete once before replay" unless probe.passed?

      job = QueueDurabilityProbeJob.perform_later(probe.probe_id)
      puts JSON.generate(event: "queue_probe_replayed", probe_id: probe.probe_id, job_id: job.job_id)
    end

    desc "Remove one completed or expired durability probe (requires PROBE_ID)"
    task cleanup: :environment do
      probe = QueueDurabilityProbeTasks.find_probe!
      abort "Probe is neither complete nor expired" unless probe.passed? || probe.expires_at <= Time.current

      probe.destroy!
      puts JSON.generate(event: "queue_probe_removed", probe_id: probe.probe_id)
    end
  end
end
