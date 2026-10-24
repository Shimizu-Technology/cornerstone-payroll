# frozen_string_literal: true

class StagingExecutionGate
  MAINTENANCE_TASKS = %w[
    db:version db:integrity db:migrate db:prepare db:safe_prepare db:abort_if_pending_migrations
    solid_queue:setup staging:clone:quarantine staging:clone:configure
    staging:clone:verify staging:readiness production:readiness
  ].freeze

  def self.maintenance_only?(tasks)
    tasks.any? && tasks.all? { |task| MAINTENANCE_TASKS.include?(task) }
  end

  def self.enforce!
    return true unless StagingOutboundPolicy.staging?
    unless StagingQuarantine.complete?
      raise StagingOutboundPolicy::ConfigurationError, "Staging execution is held: run staging:clone:quarantine, migrate, then staging:clone:configure before web/worker boot"
    end
    true
  end
end
