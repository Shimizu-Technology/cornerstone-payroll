# frozen_string_literal: true

require "rails_helper"
require "tempfile"
require "rake"

RSpec.describe "Historical prior overtime policy packet" do
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
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: run, hours_worked: 8, overtime_hours: 2) }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:category) { { "id" => "1", "key" => "maintenance", "name" => "Maintenance" } }
  let(:adjustment) do
    { "source_time_entry_id" => "41", "source_time_entry_version" => 2, "line_key" => "maintenance", "source_kind" => "current",
      "original_work_date" => "2026-08-14", "original_week_start" => "2026-08-09", "category" => category,
      "source_category_id" => "1", "total_hours" => 10.0, "regular_hours" => 10.0, "overtime_hours" => 0 }
  end
  let(:payload) do
    body = { "batch_id" => "AIRE-HISTORY-SYNTHETIC", "schema_version" => "2.0", "source" => "aire_services",
      "start_date" => "2026-08-01", "end_date" => "2026-08-15", "cutoff_at" => "2026-08-31T03:00:00Z",
      "generated_at" => "2026-08-31T03:00:00Z", "exclusions" => [],
      "employees" => [ { "source_user_id" => "91", "source_user_uuid" => uuid, "total_hours" => 10.0,
        "regular_hours" => 10.0, "overtime_hours" => 0, "adjustments" => [ adjustment ] } ],
      "summary" => { "employee_count" => 1, "adjustment_count" => 1, "exclusion_count" => 0, "total_hours" => 10.0,
        "regular_hours" => 10.0, "overtime_hours" => 0, "current_count" => 1, "carryover_count" => 0, "correction_count" => 0 },
      "issues" => %w[missing_category_count negative_adjustment_count pending_approval_count denied_approval_count open_clock_count pending_overtime_count denied_overtime_count].index_with { 0 } }
    body.merge("export" => { "id" => body["batch_id"], "batch_id" => body["batch_id"], "readiness_status" => "finalized",
      "checksum" => TimeTracking::CanonicalPayload.checksum(body), "checksum_scope" => "payload_without_export",
      "checksum_algorithm" => "SHA-256", "cutoff_at" => body["cutoff_at"], "finalized_at" => body["cutoff_at"] })
  end
  let(:row) do
    { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 10.0, "work_date" => "2026-08-14",
      "employee" => { "id" => "91" }, "category" => category,
      "state" => { "status" => "completed", "approval_status" => "approved" },
      "history_evidence" => { "payable_content_checksum" => "a" * 64, "active_manual_allocation_ids" => [],
        "payable_segments" => [ { "work_date" => "2026-08-14", "total_hours" => "10.0" } ],
        "active_cases" => [], "payment_attestation" => nil, "baseline_lines" => [ {
          "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"),
          "batch_start_date" => payload["start_date"], "batch_end_date" => payload["end_date"],
          "source_time_entry_id" => "41", "source_time_entry_version" => 2, "source_user_uuid" => uuid, "source_user_id" => "91",
          "line_key" => "maintenance", "source_kind" => "current", "work_date" => "2026-08-14", "category" => category,
          "regular_hours" => 10.0, "overtime_hours" => 0, "total_hours" => 10.0,
          "snapshot_checksum" => "f" * 64, "current_content_matches" => true, "processing_conflict" => false,
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


  def install_policy!
    input = { "source_time_entry_id" => "41", "source_user_id" => "91", "source_user_uuid" => uuid,
      "version" => 2, "work_date" => row["work_date"], "hours" => "10.0", "payable_content_checksum" => "a" * 64,
      "frozen_rows" => [ { "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"),
        "line_key" => "maintenance", "snapshot_checksum" => "f" * 64 } ] }
    proof = { "kind" => TimeTracking::PriorOvertimePolicyReview::KIND, "policy" => TimeTracking::PriorOvertimePolicyReview::POLICY,
      "threshold_evidence" => { "basis" => "owner_reviewed_8_40_fallback_no_versioned_setting_history" },
      "input_scope" => "all_effective_frozen_current_lines_in_workweek_through_batch_end",
      "source_instance_id" => source.expected_source_instance_id, "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"),
      "employees" => [ { "source_user_id" => "91", "source_user_uuid" => uuid, "eligible" => true, "blockers" => [],
        "inputs" => [ input ], "inputs_checksum" => TimeTracking::CanonicalPayload.checksum([ input ]),
        "allocations" => [ { "source_time_entry_id" => "41", "line_key" => "maintenance", "regular_hours" => "8.0", "overtime_hours" => "2.0" } ] } ] }
    payload["export"]["prior_overtime_policy"] = proof.merge("evidence_checksum" => TimeTracking::CanonicalPayload.checksum(proof))
  end

  def reviewed_packet
    packet = rollout(manifest).capture_review_packet!
    packet["reviewed_dispositions"].sole.merge!("disposition" => "paid_under_prior_daily_weekly_ot_policy",
      "reason" => "Review the preserved daily8 weekly40 historical accounting policy",
      "evidence" => "Authenticated frozen source, original allocator and committed register")
    packet["rounding_variance_acknowledgements"] = packet["rounding_variances"].map do |variance|
      variance.except("within_limit", "acknowledged").merge("type" => "accountant_reviewed_rounding_variance", "reviewer_id" => actor.id,
        "reason" => "Review the exact signed historical policy rounding difference",
        "evidence" => "Authenticated source and committed employee category totals")
    end
    packet
  end

  before { install_policy! }

  it "verifies reviewed category attribution with every existing frozen-source fence" do
    TimeTrackingCategoryMapping.create!(company: company, time_tracking_source: source, source_category_key: "maintenance",
      historical_attribution: true, historical_employee_ids: [ employee.id ], history_through_on: run.end_date,
      reviewed_by: actor, reason: "Reviewed committed historical earning attribution", evidence: "Owner decision and retained authenticated frozen source")
    packet = rollout(manifest).capture_review_packet!
    record = packet["reviewed_dispositions"].sole
    record.merge!("disposition" => "accountant_attributed_paid_category", "reason" => "Accountant attests the committed category attribution",
      "evidence" => "Reviewed historical source category and committed Payroll component")
    expect(record["attributed_categories"]).to be_present
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
    changed = packet.deep_dup
    changed["reviewed_dispositions"].sole["attributed_categories"].sole["rows"].sole["source_hours"] = "9.0"
    expect(rollout(changed).preview![:history_coverage_verified]).to be(false)
    row["version"] += 1
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
    row["version"] -= 1
    item.update_columns(hours_worked: 8.06)
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
    expect(CheckEvent.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end

  it "accepts a truthful prior policy while retaining the immutable weekly split and no payment writes" do
    packet = reviewed_packet
    evidence = packet["reviewed_dispositions"].sole["prior_overtime_policy"].sole
    expect(evidence).to include("frozen_split" => { "regular_hours" => "10.0", "overtime_hours" => "0.0" },
      "prior_policy_split" => { "regular_hours" => "8.0", "overtime_hours" => "2.0" })
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
    expect {
      rollout(packet).apply!(accepted_manifest_sha256: Digest::SHA256.hexdigest(JSON.generate(packet)), release_owner: "Rehearsal reviewer")
    }.to change(AireVerifiedHistoryRolloutReceipt, :count).by(1)
      .and change(CheckEvent, :count).by(0).and change(TimeTrackingManualAllocation, :count).by(0)
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
    expect(payload["employees"].sole["regular_hours"]).to eq(10.0)
  end

  it "requires exact employee total tie and separately acknowledged bounded REG and OT rounding" do
    item.update_columns(hours_worked: 8.03, overtime_hours: 1.97)
    packet = reviewed_packet
    expect(packet["rounding_variances"].pluck("signed_difference")).to contain_exactly("0.03", "-0.03")
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
    packet["rounding_variance_acknowledgements"] = []
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
    item.update_columns(hours_worked: 8.06, overtime_hours: 1.94)
    expect(rollout(reviewed_packet).preview![:history_coverage_verified]).to be(false)
    item.update_columns(hours_worked: 8.03, overtime_hours: 2)
    preview = rollout(reviewed_packet).preview!
    expect(preview[:history_coverage_verified]).to be(false)
    expect(reviewed_packet["reviewed_dispositions"].sole["prior_overtime_policy"]).to eq([])
  end

  it "does not retain a failed prior-policy variance when the original frozen split matches paid hours" do
    item.update_columns(hours_worked: 10, overtime_hours: 0)
    packet = rollout(manifest).capture_review_packet!
    expect(packet["rounding_variances"]).to eq([])
    expect(packet["reviewed_dispositions"].sole["prior_overtime_policy"]).to eq([])
    packet["reviewed_dispositions"].sole.merge!("disposition" => "historical_baseline",
      "reason" => "Review the unchanged frozen split actually present in the committed run",
      "evidence" => "Authenticated original frozen source matches committed REG10 OT0 exactly")
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
  end

  it "keeps a NULL approval pending while verifying its represented prior-policy baseline" do
    row["state"]["approval_status"] = nil
    packet = reviewed_packet
    packet["reviewed_dispositions"].sole["disposition"] = "pending_review"
    expect(rollout(packet).preview![:history_coverage_verified]).to be(true)
    expect(rollout(packet).preview![:rounding_variances]).to eq([])
    expect(row.dig("state", "approval_status")).to be_nil
    expect(CheckEvent.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end

  it "refuses stale sources or committed registers after acknowledgement and never trusts a manifest policy label" do
    packet = reviewed_packet
    item.update_columns(hours_worked: 7, overtime_hours: 3)
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
    item.update_columns(hours_worked: 8, overtime_hours: 2)
    row["version"] = 3
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
    row["version"] = 2
    packet["reviewed_dispositions"].sole["prior_overtime_policy"].sole["policy"] = { "name" => "invented_policy" }
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
  end

  it "refuses missing context, changed identity, tampered export and thresholds outside the authenticated contract" do
    pristine = payload["export"]["prior_overtime_policy"].deep_dup
    [ :context, :identity, :threshold, :digest ].each do |kind|
      proof = pristine.deep_dup
      case kind
      when :context then proof["employees"].sole["inputs"].sole["source_time_entry_id"] = "missing"
      when :identity then proof["employees"].sole["source_user_uuid"] = SecureRandom.uuid
      when :threshold then proof["policy"] = proof["policy"].merge("daily_threshold_hours" => "6.0")
      when :digest then proof["evidence_checksum"] = "0" * 64
      end
      proof["evidence_checksum"] = TimeTracking::CanonicalPayload.checksum(proof.except("evidence_checksum")) unless kind == :digest
      payload["export"]["prior_overtime_policy"] = proof
      expect(rollout(reviewed_packet).preview![:history_coverage_verified]).to be(false)
    end
  end
  it "keeps Flight0.60 versus paid3.10 blocked even when another component offsets the difference" do
    category.replace("id" => "1", "key" => "flight", "name" => "Flight Hours")
    ground = { "id" => "2", "key" => "ground", "name" => "Ground Instruction Hours" }
    adjustment.merge!("total_hours" => 0.6, "regular_hours" => 0.6)
    extra_line = adjustment.deep_dup.merge("source_time_entry_id" => "42", "line_key" => "ground", "category" => ground,
      "source_category_id" => "2", "total_hours" => 9.4, "regular_hours" => 9.4)
    payload["employees"].sole["adjustments"] << extra_line
    payload["summary"].merge!("adjustment_count" => 2, "current_count" => 2)
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["category"] = category
    row["hours"] = 0.6
    row["history_evidence"]["payable_segments"].sole["total_hours"] = "0.6"
    row["history_evidence"]["baseline_lines"].sole.merge!("category" => category, "total_hours" => 0.6, "regular_hours" => 0.6,
      "batch_checksum" => payload.dig("export", "checksum"))
    extra = row.deep_dup.merge("id" => "42", "category" => ground, "hours" => 9.4)
    extra["history_evidence"].merge!("payable_content_checksum" => "b" * 64,
      "payable_segments" => [ { "work_date" => row["work_date"], "total_hours" => "9.4" } ])
    extra["history_evidence"]["baseline_lines"].sole.merge!("source_time_entry_id" => "42", "line_key" => "ground",
      "category" => ground, "total_hours" => 9.4, "regular_hours" => 9.4, "snapshot_checksum" => "e" * 64)
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(
      "source_state" => "current", "history_evidence_version" => 1, "unresolved_historical_obligation_count" => 0,
      "integration" => { "source_instance_id" => source.expected_source_instance_id }, "through_work_date" => "2026-08-15",
      "time_entries" => [ row, extra ], "pagination" => { "current_page" => 1, "per_page" => 50, "total_count" => 2, "total_pages" => 1, "truncated" => false })
    proof = payload["export"]["prior_overtime_policy"]
    proof["batch_checksum"] = payload.dig("export", "checksum")
    original_input = proof["employees"].sole["inputs"].sole
    original_input["hours"] = "0.6"
    original_input["frozen_rows"].sole["batch_checksum"] = proof["batch_checksum"]
    new_input = original_input.deep_dup.merge("source_time_entry_id" => "42", "hours" => "9.4", "payable_content_checksum" => "b" * 64)
    new_input["frozen_rows"].sole.merge!("line_key" => "ground", "snapshot_checksum" => "e" * 64)
    proof["employees"].sole["inputs"] << new_input
    proof["employees"].sole["inputs_checksum"] = TimeTracking::CanonicalPayload.checksum(proof["employees"].sole["inputs"])
    proof["employees"].sole["allocations"] = [
      { "source_time_entry_id" => "41", "line_key" => "maintenance", "regular_hours" => "0.6", "overtime_hours" => "0.0" },
      { "source_time_entry_id" => "42", "line_key" => "ground", "regular_hours" => "7.4", "overtime_hours" => "2.0" } ]
    proof["evidence_checksum"] = TimeTracking::CanonicalPayload.checksum(proof.except("evidence_checksum"))
    item.update_columns(custom_columns_data: { "wage_rate_hours" => [
      { "employee_wage_rate_id" => 11, "label" => "Flight Hours", "active" => true, "rate" => 10, "regular_hours" => 3.1, "overtime_hours" => 0 },
      { "employee_wage_rate_id" => 12, "label" => "Ground Instruction Hours", "active" => true, "rate" => 10, "regular_hours" => 4.9, "overtime_hours" => 2 } ] })
    packet = rollout(manifest).capture_review_packet!
    packet["historical_earning_component_bindings"] = packet["rounding_review_blockers"].select { |blocker| blocker["source_category"] }.map do |blocker|
      blocker.except("reason").merge("type" => "historical_earning_component_binding", "reviewer_id" => actor.id,
        "earning_component" => blocker["source_category"] == category ? "wage_rate:11" : "wage_rate:12",
        "reason" => "Reviewed exact source category to committed earning component",
        "evidence" => "Synthetic explicit component labels; employee total ties")
    end
    packet["reviewed_dispositions"].each { |record| record.merge!("disposition" => "paid_under_prior_daily_weekly_ot_policy",
      "reason" => "Review prior policy separately for every earning component", "evidence" => "Synthetic authenticated source and committed component evidence") }
    preview = rollout(packet).preview!
    expect(preview[:history_coverage_verified]).to be(false)
    expect(preview[:rounding_variances]).to include(a_hash_including("source_category" => category, "source_total" => "0.6", "paid_total" => "3.1", "signed_difference" => "2.5"))
  end
  it "rejects an authenticated calculation that omits a real preceding-period frozen context line" do
    prior_evidence = reviewed_packet["reviewed_dispositions"].sole["prior_overtime_policy"]
    previous_run = create(:pay_period, :committed, company: company, start_date: "2026-07-16", end_date: "2026-07-31", pay_date: "2026-08-15")
    create(:payroll_item, company: company, employee: employee, pay_period: previous_run, hours_worked: 5, overtime_hours: 0)
    previous_payload = payload.deep_dup
    previous_payload.merge!("batch_id" => "FROZEN-PRECEDING-CONTEXT", "start_date" => "2026-07-16", "end_date" => "2026-07-31")
    previous_payload["employees"].sole.merge!("total_hours" => 5.0, "regular_hours" => 5.0)
    previous_payload["employees"].sole["adjustments"].sole.merge!("source_time_entry_id" => "40", "line_key" => "preceding",
      "original_work_date" => "2026-07-31", "original_week_start" => "2026-07-26", "total_hours" => 5.0, "regular_hours" => 5.0)
    previous_payload["summary"].merge!("total_hours" => 5.0, "regular_hours" => 5.0)
    previous_payload["export"].delete("prior_overtime_policy")
    previous_payload["export"].merge!("id" => previous_payload["batch_id"], "batch_id" => previous_payload["batch_id"],
      "checksum" => TimeTracking::CanonicalPayload.checksum(previous_payload.except("export")))
    previous = row.deep_dup.merge("id" => "40", "work_date" => "2026-07-31", "hours" => 5.0)
    previous["history_evidence"]["payable_segments"] = [ { "work_date" => "2026-07-31", "total_hours" => "5.0" } ]
    previous["history_evidence"]["baseline_lines"].sole.merge!("source_time_entry_id" => "40", "line_key" => "preceding", "work_date" => "2026-07-31",
      "batch_id" => previous_payload["batch_id"], "batch_checksum" => previous_payload.dig("export", "checksum"),
      "batch_start_date" => "2026-07-16", "batch_end_date" => "2026-07-31", "total_hours" => 5.0, "regular_hours" => 5.0,
      "processing" => { "status" => "committed", "external_system" => "cornerstone_payroll_manual", "external_pay_period_id" => previous_run.id.to_s })
    allow(client).to receive(:payroll_batch) { |batch_id:| batch_id == previous_payload["batch_id"] ? previous_payload : payload }
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(
      "source_state" => "current", "history_evidence_version" => 1, "unresolved_historical_obligation_count" => 0,
      "integration" => { "source_instance_id" => source.expected_source_instance_id }, "through_work_date" => "2026-08-15",
      "time_entries" => [ previous, row ], "pagination" => { "current_page" => 1, "per_page" => 50, "total_count" => 2, "total_pages" => 1, "truncated" => false })
    packet = rollout(manifest).capture_review_packet!
    packet["reviewed_dispositions"].each do |record|
      record.merge!("reason" => "Review complete preceding-period context without omitting worked hours",
        "evidence" => "Synthetic two authenticated frozen batches and committed employee registers")
      record["disposition"] = record["source_time_entry_id"] == "40" ? "historical_baseline" : "paid_under_prior_daily_weekly_ot_policy"
      record["prior_overtime_policy"] = prior_evidence if record["source_time_entry_id"] == "41"
    end
    expect(rollout(packet).preview![:history_coverage_verified]).to be(false)
  end
end
