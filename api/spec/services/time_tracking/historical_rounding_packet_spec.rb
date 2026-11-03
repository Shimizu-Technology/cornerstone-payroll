# frozen_string_literal: true

require "rails_helper"
require "tempfile"
require "rake"

RSpec.describe "Reviewed historical rounding packet" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:uuid) { SecureRandom.uuid }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES)
  end
  let(:run) { create(:pay_period, :committed, company: company, start_date: "2026-08-01", end_date: "2026-08-15", pay_date: "2026-08-31") }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 6.13, overtime_hours: 0) }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:category) { { "id" => "1", "key" => "maintenance", "name" => "Maintenance" } }
  let(:adjustment) do
    { "source_time_entry_id" => "41", "source_time_entry_version" => 2, "line_key" => "maintenance", "source_kind" => "current",
      "original_work_date" => "2026-08-14", "original_week_start" => "2026-08-09", "category" => category,
      "source_category_id" => "1", "total_hours" => 6.1, "regular_hours" => 6.1, "overtime_hours" => 0 }
  end
  let(:payload) do
    body = { "batch_id" => "AIRE-HISTORY-SYNTHETIC", "schema_version" => "2.0", "source" => "aire_services",
      "start_date" => "2026-08-01", "end_date" => "2026-08-15", "cutoff_at" => "2026-08-31T03:00:00Z",
      "generated_at" => "2026-08-31T03:00:00Z", "exclusions" => [],
      "employees" => [ { "source_user_id" => "91", "source_user_uuid" => uuid, "total_hours" => 6.1,
        "regular_hours" => 6.1, "overtime_hours" => 0, "adjustments" => [ adjustment ] } ],
      "summary" => { "employee_count" => 1, "adjustment_count" => 1, "exclusion_count" => 0, "total_hours" => 6.1,
        "regular_hours" => 6.1, "overtime_hours" => 0, "current_count" => 1, "carryover_count" => 0, "correction_count" => 0 },
      "issues" => %w[missing_category_count negative_adjustment_count pending_approval_count denied_approval_count open_clock_count pending_overtime_count denied_overtime_count].index_with { 0 } }
    body.merge("export" => { "id" => body["batch_id"], "batch_id" => body["batch_id"], "readiness_status" => "finalized",
      "checksum" => TimeTracking::CanonicalPayload.checksum(body), "checksum_scope" => "payload_without_export",
      "checksum_algorithm" => "SHA-256", "cutoff_at" => body["cutoff_at"], "finalized_at" => body["cutoff_at"] })
  end
  let(:row) do
    { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.1, "work_date" => "2026-08-14",
      "employee" => { "id" => "91" }, "category" => category,
      "state" => { "status" => "completed", "approval_status" => "approved" },
      "history_evidence" => { "payable_content_checksum" => "a" * 64, "active_manual_allocation_ids" => [],
        "active_cases" => [], "payment_attestation" => nil, "baseline_lines" => [ {
          "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"),
          "batch_start_date" => payload["start_date"], "batch_end_date" => payload["end_date"],
          "source_time_entry_id" => "41", "source_time_entry_version" => 2, "source_user_uuid" => uuid,
          "line_key" => "maintenance", "source_kind" => "current", "work_date" => "2026-08-14", "category" => category,
          "regular_hours" => 6.1, "overtime_hours" => 0, "total_hours" => 6.1,
          "current_content_matches" => true, "processing_conflict" => false,
          "processing" => { "status" => "committed", "external_system" => "cornerstone_payroll_manual", "external_pay_period_id" => run.id.to_s }
        } ] } }
  end
  let(:manifest) do
    { "version" => 1, "company_id" => company.id, "company_name" => company.name, "source_id" => source.id,
      "source_instance_id" => source.expected_source_instance_id, "actor_id" => actor.id,
      "history_through_work_date" => "2026-08-15", "identity_links" => [], "delivered_checks" => [],
      "issued_entries" => [], "classification_cases" => [], "finalized_batch_entries" => [] }
  end

  before do
    item
    source.update_column(:historical_reconciliation_required, true)
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: "91", source_user_uuid: uuid)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).and_return(client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => {
      "connected" => true, "aire_user_email" => actor.email
    })
    allow(client).to receive(:payroll_batch).and_return(payload)
    allow(client).to receive(:payroll_cockpit_history_entries) do
      { "source_state" => "current", "history_evidence_version" => 1, "unresolved_historical_obligation_count" => 0,
        "integration" => { "source_instance_id" => source.expected_source_instance_id }, "through_work_date" => "2026-08-15",
        "time_entries" => [ row ], "pagination" => { "current_page" => 1, "per_page" => 50, "total_count" => 1, "total_pages" => 1, "truncated" => false } }
    end
  end

  def rollout(packet)
    TimeTracking::VerifiedHistoryRollout.new(manifest: packet, actor: actor)
  end

  it "keeps a whole frozen overtime exclusion pending with no historical payment claim" do
    row["hours"] = 0.3
    row["state"]["overtime_status"] = "pending"
    row["history_evidence"]["baseline_lines"] = []
    payload["employees"] = []
    payload["exclusions"] = [ {
      "source_time_entry_id" => "41", "source_user_id" => "91", "source_user_uuid" => uuid,
      "original_work_date" => "2026-08-14", "category" => category, "reason" => "pending_overtime",
      "held_total_hours" => 0.3, "held_regular_hours" => 0, "held_overtime_hours" => 0.3
    } ]
    payload["summary"].merge!("employee_count" => 0, "adjustment_count" => 0, "exclusion_count" => 1,
      "total_hours" => 0, "regular_hours" => 0, "overtime_hours" => 0, "current_count" => 0)
    payload["issues"]["pending_overtime_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["history_evidence"]["pending_overtime"] = { "kind" => "pending_overtime", "source_time_entry_version" => 2,
      "payable_content_checksum" => "a" * 64, "represented_regular_hours" => "0.0",
      "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"),
      "frozen_exclusion" => payload["exclusions"].sole.deep_dup }
    packet = rollout(manifest).capture_review_packet!
    packet["reviewed_dispositions"].sole.merge!("disposition" => "pending_overtime",
      "reason" => "Keep this exact whole frozen overtime exclusion pending for approval",
      "evidence" => "Synthetic authenticated frozen hold; no payment or allocation evidence")
    expect(rollout(packet).preview!).to include(history_coverage_verified: true, disposition_counts: { "pending_overtime" => 1 })
    pristine = row.deep_dup
    [ [ "hours", 0.4 ], [ "state", row["state"].merge("overtime_status" => "approved") ],
      [ "history_evidence", row["history_evidence"].merge("pending_overtime" => nil) ] ].each do |key, value|
      row.replace(pristine.deep_dup.merge(key => value))
      recaptured = rollout(manifest).capture_review_packet!
      recaptured["reviewed_dispositions"].sole.merge!(packet["reviewed_dispositions"].sole.except("source"))
      expect(rollout(recaptured).preview!).to include(history_coverage_verified: false)
    end
  end

  it "verifies a complete checksum-bound regular baseline plus an exact pending overtime exclusion" do
    item.update_columns(hours_worked: 6.1)
    row["hours"] = 6.4
    row["state"]["overtime_status"] = "none"
    payload["exclusions"] = [ {
      "source_time_entry_id" => "41", "source_time_entry_version" => 2, "source_user_id" => "91", "source_user_uuid" => uuid,
      "original_work_date" => "2026-08-14", "original_week_start" => "2026-08-09", "category" => category,
      "source_category_id" => "1", "reason" => "pending_overtime", "held_total_hours" => 0.3,
      "held_regular_hours" => 0, "held_overtime_hours" => 0.3
    } ]
    payload["summary"]["exclusion_count"] = 1
    payload["issues"]["pending_overtime_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["history_evidence"]["baseline_lines"].sole["batch_checksum"] = payload.dig("export", "checksum")
    packet = rollout(manifest).capture_review_packet!
    packet["reviewed_dispositions"].sole.merge!("disposition" => "historical_baseline_pending_overtime",
      "reason" => "Review represented regular hours and preserve the frozen overtime hold",
      "evidence" => "Synthetic authenticated batch, exact pending exclusion and committed run")
    expect(rollout(packet).preview!).to include(history_coverage_verified: true,
      disposition_counts: { "historical_baseline_pending_overtime" => 1 })
    expect {
      rollout(packet).apply!(accepted_manifest_sha256: Digest::SHA256.hexdigest(JSON.generate(packet)), release_owner: "Synthetic rehearsal reviewer")
    }.to change(AireVerifiedHistoryRolloutReceipt, :count).by(1)
      .and change(TimeTrackingManualAllocation, :count).by(0)
      .and change(CheckEvent, :count).by(0)
    row["state"]["overtime_status"] = "approved"
    expect(rollout(packet).preview!).to include(history_coverage_verified: false)
  end

  it "exports unsigned variances, requires each signed review, applies coverage only, and refuses a stale run receipt" do
    packet = rollout(manifest).capture_review_packet!
    expect(packet.fetch("rounding_variance_acknowledgements")).to eq([])
    expect(packet.fetch("rounding_variances").sole).to include("signed_difference" => "0.03", "acknowledged" => false)
    expect(packet.fetch("reviewed_dispositions").sole).to include("disposition" => "review_required", "reason" => "", "evidence" => "")
    packet.fetch("reviewed_dispositions").sole.merge!("disposition" => "historical_baseline",
      "reason" => "Reviewed synthetic manual payroll baseline", "evidence" => "Synthetic authenticated frozen source and committed register")
    expect(rollout(packet).preview!).to include(history_coverage_verified: false)
    packet["rounding_variance_acknowledgements"] = packet.fetch("rounding_variances").map do |variance|
      variance.except("within_limit", "acknowledged").merge("type" => "accountant_reviewed_rounding_variance", "reviewer_id" => actor.id,
        "reason" => "Reviewed signed neutral rounding under the approved policy", "evidence" => "Synthetic exact committed register and source comparison")
    end
    result = rollout(packet).preview!
    expect(result).to include(history_coverage_verified: true, disposition_counts: { "historical_baseline" => 1 })
    expect(TimeTracking::HistoryRoundingTable.render(result.fetch(:rounding_variances))).to include("Paid-minus-source", "0.03", "yes")
    bytes = JSON.generate(packet)
    digest = Digest::SHA256.hexdigest(bytes)
    expect {
      rollout(packet).apply!(accepted_manifest_sha256: digest, release_owner: "Synthetic rehearsal reviewer")
    }.to change(AireVerifiedHistoryRolloutReceipt, :count).by(1)
      .and change(TimeTrackingManualAllocation, :count).by(0)
      .and change(CheckEvent, :count).by(0)
      .and change(PayrollItem, :count).by(0)
    expect(source.reload.historical_reconciliation_complete?).to be(true)
    Tempfile.create("rounding-packet", mode: 0o600) do |file|
      file.write(bytes)
      file.flush
      saved = ENV.to_h.slice("AIRE_ROLLOUT_MANIFEST_PATH", "AIRE_ROLLOUT_MANIFEST_SHA256")
      begin
        ENV["AIRE_ROLLOUT_MANIFEST_PATH"], ENV["AIRE_ROLLOUT_MANIFEST_SHA256"] = file.path, digest
        Rails.application.load_tasks unless Rake::Task.task_defined?("aire_rollout:ensure_complete")
        task = Rake::Task["aire_rollout:ensure_complete"]
        task.reenable
        expect { task.invoke }.not_to raise_error
        item.update_columns(hours_worked: 6.12)
        task.reenable
        expect { task.invoke }.to raise_error(/Fresh AIRE historical coverage is incomplete/)
        expect(AireVerifiedHistoryRolloutReceipt.last.coverage_verified).to be(true)
      ensure
        %w[AIRE_ROLLOUT_MANIFEST_PATH AIRE_ROLLOUT_MANIFEST_SHA256].each do |key|
          saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key)
        end
      end
    end
  end
end
