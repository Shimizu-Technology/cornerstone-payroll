# frozen_string_literal: true

# Lightweight production dependency probes for monitoring and incident triage.
# These checks are read-only and deliberately avoid Rails.cache so they still
# report accurately while the primary database is in a read-only state.
class DependencyHealth
  WORKER_HEARTBEAT_WINDOW = 5.minutes

  Check = Data.define(:name, :passed)

  class Report
    attr_reader :checks, :generated_at, :revision

    def initialize(checks:, generated_at: Time.current,
                   revision: ENV.fetch("RENDER_GIT_COMMIT", ENV.fetch("GIT_COMMIT", "unknown")))
      @checks = checks
      @generated_at = generated_at
      @revision = revision
    end

    def ready?
      checks.all?(&:passed)
    end

    def as_json(*)
      {
        status: ready? ? "ok" : "degraded",
        generated_at: generated_at.iso8601,
        revision: revision,
        checks: checks.to_h { |check| [ check.name, check.passed ] }
      }
    end
  end

  def initialize(primary_record: ActiveRecord::Base, queue_process: SolidQueue::Process, clock: -> { Time.current })
    @primary_record = primary_record
    @queue_process = queue_process
    @clock = clock
  end

  def run
    Report.new(checks: [
      check("primary_database") { primary_connection.select_value("SELECT 1").to_i == 1 },
      check("primary_writable") { primary_connection.select_value("SHOW transaction_read_only") == "off" },
      check("primary_role") { primary_connection.select_value("SELECT pg_is_in_recovery()") == false },
      check("queue_worker") do
        queue_process.where(
          kind: "Worker",
          last_heartbeat_at: (clock.call - WORKER_HEARTBEAT_WINDOW)..
        ).exists?
      end
    ])
  end

  private

  attr_reader :primary_record, :queue_process, :clock

  def primary_connection
    primary_record.connection
  end

  def check(name)
    Check.new(name: name, passed: yield == true)
  rescue StandardError
    Check.new(name: name, passed: false)
  end
end
