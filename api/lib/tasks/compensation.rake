# frozen_string_literal: true

require_relative "../rls_task"

namespace :compensation do
  desc "Fail when code writes pay rates or compensation history outside EmployeeCompensationChangeService"
  task lint_writes: :environment do
    require Rails.root.join("lib/compensation_write_lint")
    offenses = CompensationWriteLint.offenses
    if offenses.any?
      warn "Pay rates change only through EmployeeCompensationChangeService (M3-4):"
      offenses.each { |offense| warn "  #{offense}" }
      abort "#{offenses.size} compensation write-path offense(s)"
    end
    puts "Compensation write path clean"
  end

  desc "Record legacy compensation writes made after the migration's backfill"
  RlsTask.system reconcile_rollout: :environment do
    employee_count = 0
    rate_count = 0
    today = PayrollBusinessClock.today
    actor = AuditActor.system_job(EmployeeCompensationChangeService::ROLLOUT_ACTOR_NAME)
    Employee.in_batches do |batch|
      batch.ids.each do |employee_id|
        result = EmployeeCompensationChangeService.reconcile_rollout!(employee_id, as_of: today, actor: actor)
        next unless result

        employee_count += 1
        rate_count += result.fetch(:wage_rate_ids).size
        puts "employee_id=#{employee_id} wage_rate_ids=#{result.fetch(:wage_rate_ids).join(',')}"
      rescue StandardError => error
        abort "Compensation reconciliation stopped at employee_id=#{employee_id} (#{error.class})"
      end
    end
    puts "employee_count=#{employee_count} wage_rate_count=#{rate_count}"
  end

  desc "Refresh pay-rate cache columns from the versions in effect today"
  RlsTask.system sync_effective: :environment do
    SyncEffectiveCompensationJob.perform_now
    puts "Compensation cache refreshed"
  end
end
