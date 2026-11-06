# frozen_string_literal: true

# The browser exercises the real queued UI request. The disposable test lane
# explicitly drains this one job; it does not stand in for a hosted worker test.
require "json"

database_name = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" && database_name.start_with?("cornerstone_aire_certification_")
  abort "Refusing browser queue draining outside the isolated certification database"
end
fixture = JSON.parse(File.read(ENV.fetch("E2E_CONNECTED_FIXTURE_PATH")))
generation = CheckPrintGeneration.find(Integer(ENV.fetch("CONNECTED_BROWSER_GENERATION_ID"), 10))
unless generation.pay_period_id == fixture.fetch("manual_browser_pay_period_id") &&
       generation.requested_by_id == fixture.fetch("manual_accountant_id") &&
       generation.company_id == fixture.fetch("company_id")
  abort "Browser generation does not belong to the dedicated manual accountant fixture"
end
CheckPrintGenerationJob.perform_now(generation.id)
generation.reload
abort "Browser package generation did not complete: #{generation.status}" unless generation.status == "ready"
