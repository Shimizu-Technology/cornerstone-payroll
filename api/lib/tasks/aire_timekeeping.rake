# frozen_string_literal: true

namespace :timekeeping do
  desc "Preview/apply the explicit AIRE salary timekeeping backfill (dry-run by default)"
  task aire_salary_backfill: :environment do
    required = %w[COMPANY_ID EMPLOYEE_ID EXPECTED_EMPLOYEE_NAME EFFECTIVE_ON ACTOR_USER_ID]
    missing = required.select { |key| ENV[key].blank? }
    abort "Missing required values: #{missing.join(', ')}" if missing.any?

    actor = User.find(ENV.fetch("ACTOR_USER_ID"))
    result = AireSalaryTimekeepingBackfillService.call!(
      company_id: ENV.fetch("COMPANY_ID"),
      employee_id: ENV.fetch("EMPLOYEE_ID"),
      expected_employee_name: ENV.fetch("EXPECTED_EMPLOYEE_NAME"),
      effective_on: ENV.fetch("EFFECTIVE_ON"),
      actor: actor,
      apply: ENV["APPLY"] == "true"
    )
    puts JSON.pretty_generate(result)
    puts("DRY RUN ONLY. Re-run with APPLY=true after the preview is reviewed.") unless result[:apply]
  rescue AireSalaryTimekeepingBackfillService::Error => e
    abort e.message
  end
end
