# frozen_string_literal: true

require "json"
require "rake"
raise "Synthetic test fixture only" unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
  ActiveRecord::Base.connection_db_config.database.include?("_certification_rollout_rehearsal_")

fixture = JSON.parse(File.read(ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH")))
source = TimeTrackingSource.sole
actor = User.find_by!(email: "cornerstone-certification-admin@example.test")
period = source.company.pay_periods.where(status: "committed").order(:end_date).last!
manifest = { "version" => 1, "company_id" => source.company_id, "company_name" => source.company.name,
  "source_id" => source.id, "source_instance_id" => source.expected_source_instance_id, "actor_id" => actor.id,
  "history_through_work_date" => period.end_date.iso8601, "identity_links" => [], "delivered_checks" => [],
  "issued_entries" => [], "classification_cases" => [], "finalized_batch_entries" => [] }
export_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
packet = TimeTracking::VerifiedHistoryRollout.new(manifest: manifest, actor: actor).capture_review_packet!
puts "TIMING: authenticated history export rows=#{packet.fetch("reviewed_dispositions").length} seconds=#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - export_started).round(3)} page_size=#{ENV.fetch("AIRE_HISTORY_PAGE_SIZE", "50")} read_budget_seconds=#{ENV.fetch("AIRE_HISTORY_READ_TIMEOUT_SECONDS", "60")}"
raise "Incomplete synthetic history export" unless packet.fetch("reviewed_dispositions").length == fixture.fetch("history_entry_ids").length
packet.fetch("reviewed_dispositions").each do |review|
  row = review.fetch("source")
  evidence = row.fetch("history_evidence")
  review["disposition"] = if evidence.fetch("baseline_lines").any?
    "historical_baseline"
  elsif BigDecimal(row.fetch("hours").to_s).zero?
    "no_payable_hours"
  elsif evidence["payment_attestation"]
    "payment_evidence_pending"
  elsif row.dig("state", "approval_status") == "pending"
    "pending_review"
  elsif row.dig("state", "approval_status") == "denied"
    "not_payable"
  elsif review.fetch("source_time_entry_id") == fixture.fetch("history_owed_entry_id").to_s
    "owed"
  else
    raise "Unreviewed synthetic source"
  end
  review["reason"] = "Synthetic accountant fixture review; preserve this exact source disposition"
  review["evidence"] = "Synthetic historical register and immutable source fixture, no real payment or delivery"
end
path = File.join(File.dirname(ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH")), "history.reviewed.json")
bytes = JSON.pretty_generate(packet)
File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
digest = Digest::SHA256.hexdigest(bytes)
rollout = TimeTracking::VerifiedHistoryRollout.new(manifest: TimeTracking::VerifiedHistoryRollout.load_file!(path: path, expected_sha256: digest), actor: actor)
summary = rollout.preview!
raise "Coverage incomplete" unless summary.fetch(:history_coverage_verified) == true
before = [ TimeTrackingManualAllocation.count, TimeTrackingEntryAllocation.count, AirePayrollEntryAcknowledgement.count, CheckEvent.count ]
ENV["AIRE_ROLLOUT_MANIFEST_PATH"] = path
ENV["AIRE_ROLLOUT_MANIFEST_SHA256"] = digest
ENV["AIRE_ROLLOUT_ACCEPTED_MANIFEST_SHA256"] = digest
ENV["AIRE_ROLLOUT_RELEASE_OWNER"] = "Synthetic certification operator"
ENV["AIRE_ROLLOUT_LOCAL_TEST"] = "1"
Rails.application.load_tasks
Rake::Task["aire_rollout:apply"].invoke
Rake::Task["aire_rollout:ensure_complete"].invoke
raise "Historical approval created payment side effects" unless before ==
  [ TimeTrackingManualAllocation.count, TimeTrackingEntryAllocation.count, AirePayrollEntryAcknowledgement.count, CheckEvent.count ]
raise "Completion not persisted" unless source.reload.historical_reconciliation_complete?
puts "PASS: real HTTP historical export → six typed reviews → preview → guarded apply → fresh ensure_complete; publication now allowed"
puts summary.to_json
