# frozen_string_literal: true

require "json"

database_name = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" && database_name.start_with?("cornerstone_aire_certification_")
  abort "Refusing to certify history outside an isolated Cornerstone database"
end

fixture = JSON.parse(File.read(ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH")))
source = TimeTrackingSource.sole
actor = User.find_by!(email: "cornerstone-certification-admin@example.test")
abort "Fixture installation identity was not pinned" unless source.remote_identity_pinned?
client = TimeTracking::Client.for_payroll_actor(source, actor: actor)
history = client.payroll_cockpit_history_entries(through_work_date: fixture.fetch("end_date"))
expected_ids = fixture.values_at("ordinary_entry_id", "approved_manual_entry_id", "held_manual_entry_id").map(&:to_s)
entries = history.fetch("time_entries")
pagination = history.fetch("pagination")
abort "Historical inventory lost source entries" unless entries.map { |entry| entry.fetch("id").to_s }.sort == expected_ids.sort
unless pagination.fetch("total_count") == 3 && pagination.fetch("total_pages") == 1 && pagination.fetch("truncated") == false
  abort "Historical pagination contract is incomplete"
end
unless entries.all? { |entry| entry.fetch("source_user_uuid") == fixture.fetch("employee_uuid") && entry.fetch("version").is_a?(Integer) }
  abort "Historical inventory lost permanent identity or current version"
end
live_entry = client.payroll_cockpit_time_entry(entry_id: fixture.fetch("ordinary_entry_id")).fetch("time_entry")
abort "Legacy live identity read lost owner identity" unless live_entry.dig("employee", "payroll_integration_id") == fixture.fetch("employee_uuid")
wrong_installation = source.dup
wrong_installation.expected_source_instance_id = SecureRandom.uuid
begin
  TimeTracking::Client.new(wrong_installation).payroll_cockpit_time_entry(entry_id: fixture.fetch("ordinary_entry_id"))
  abort "Mismatched source installation was accepted"
rescue TimeTracking::Client::Error => error
  abort "Unexpected source mismatch response" unless error.response_status == 409
end
puts "PASS: pinned installation, complete historical inventory, and legacy live identity crossed the real HTTP boundary"
