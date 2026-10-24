# frozen_string_literal: true

namespace :aire_lock_rollout do
  desc "Validate and audit the Payroll lock rollout gate, including every preactivation calendar/publication"
  task configure: :environment do
    result = AirePayrollCalendar::LockRollout.new(
      source: TimeTrackingSource.find(ENV.fetch("SOURCE_ID")), starts_on: ENV.fetch("STARTS_ON"),
      actor: ENV.fetch("ACTOR"), reason: ENV.fetch("REASON")
    ).configure!
    puts result.to_json
  end
end
