# frozen_string_literal: true

require_relative "../rls_task"

namespace :aire_lock_rollout do
  desc "Read-only inventory and digest for reviewing preactivation historical imports"
  RlsTask.system preview_historical_imports: :environment do
    puts AirePayrollCalendar::HistoricalImportBoundaryReview.new(source: TimeTrackingSource.find(ENV.fetch("SOURCE_ID"))).preview!.to_json
  end

  desc "Validate and audit the Payroll lock rollout gate, including every preactivation calendar/publication"
  RlsTask.system configure: :environment do
    Current.with_isolated_actor(AuditActor.operator(ENV.fetch("ACTOR"))) do
      result = AirePayrollCalendar::LockRollout.new(
        source: TimeTrackingSource.find(ENV.fetch("SOURCE_ID")), starts_on: ENV.fetch("STARTS_ON"),
        actor: ENV.fetch("ACTOR"), reason: ENV.fetch("REASON"), historical_imports_sha256: ENV["HISTORICAL_IMPORTS_SHA256"]
      ).configure!
      puts result.to_json
    end
  end
end
