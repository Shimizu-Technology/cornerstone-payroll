# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::HistoryDispositionVerifier do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, expected_source_instance_id: SecureRandom.uuid,
    source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current) }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:uuid) { SecureRandom.uuid }
  let(:current) do
    { "id" => "1804", "version" => 2, "source_user_uuid" => uuid, "work_date" => "2026-09-15", "hours" => 4.25,
      "category" => { "id" => "1", "key" => "admin", "name" => "Admin" },
      "state" => { "status" => "completed", "approval_status" => "pending", "entry_method" => "manual" },
      "lifecycle" => { "status" => "awaiting_approval" },
      "history_evidence" => { "payable_content_checksum" => "a" * 64, "baseline_lines" => [],
        "active_manual_allocation_ids" => [], "payment_attestation" => nil, "active_cases" => [] } }
  end
  let(:disposition) do
    { "disposition" => "pending_review", "actor_id" => actor.id, "reason" => "Keep this source pending until individual accounting review",
      "evidence" => "Private reviewed register reference SYNTHETIC-1", "source_instance_id" => source.expected_source_instance_id,
      "source_time_entry_id" => current.fetch("id"), "source_user_uuid" => uuid,
      "source_time_entry_version" => current.fetch("version"), "source" => current.slice(*described_class::SOURCE_FIELDS).deep_dup }
  end
  subject(:verifier) { described_class.new(source: source, company: company, actor: actor, client: client) }

  def capture(type)
    disposition.merge!("disposition" => type, "source" => current.slice(*described_class::SOURCE_FIELDS).deep_dup)
  end

  it "keeps pending and legacy NULL approvals pending without a write" do
    expect(client).not_to receive(:payroll_batch)
    expect(verifier.verified?(disposition, current)).to be(true)
    current["state"]["approval_status"] = nil
    capture("pending_review")
    expect(verifier.verified?(disposition, current)).to be(true)
  end

  %w[source_instance_id source_time_entry_id source_user_uuid source_time_entry_version actor_id reason evidence disposition].each do |field|
    it "rejects a missing #{field}" do
      disposition.delete(field)
      expect(verifier.verified?(disposition, current)).to be(false)
    end
  end

  it "rejects a changed version, category, hours, approval, or content behind a prior review" do
    disposition
    [ [ "version", 3 ], [ "hours", 3.0 ], [ "category", nil ], [ "state", {} ], [ "history_evidence", {} ] ].each do |field, value|
      changed = current.merge(field => value)
      expect(verifier.verified?(disposition, changed)).to be(false)
    end
  end

  it "refuses a processed baseline mislabeled pending or owed" do
    current["state"]["approval_status"] = "approved"
    current["lifecycle"]["status"] = "committed"
    current["history_evidence"]["baseline_lines"] = [ {} ]
    capture("pending_review")
    expect(verifier.verified?(disposition, current)).to be(false)
    capture("owed")
    expect(verifier.verified?(disposition, current)).to be(false)
  end

  it "preserves genuinely owed, approved, unrepresented hours with one explicit routing case" do
    current["state"]["approval_status"] = "approved"
    current["lifecycle"]["status"] = "ready_for_cutoff"
    current["history_evidence"]["active_cases"] = [ { "id" => SecureRandom.uuid, "version" => 2,
      "source_user_uuid" => uuid, "status" => "open", "destination_kind" => "unassigned", "held_total_hours" => "4.25" } ]
    capture("owed")
    expect(verifier.verified?(disposition, current)).to be(true)
    current["history_evidence"]["active_cases"] << current["history_evidence"]["active_cases"].first
    capture("owed")
    expect(verifier.verified?(disposition, current)).to be(false)
  end

  it "requires an unchanged whole-source payment evidence hold" do
    current["lifecycle"]["status"] = "payment_attested_pending_evidence"
    current["history_evidence"]["payment_attestation"] = { "id" => "12", "hours" => "4.25", "source_changed" => false }
    capture("payment_evidence_pending")
    expect(verifier.verified?(disposition, current)).to be(true)
    [ { "source_changed" => true }, { "hours" => "4.0" } ].each do |change|
      current["history_evidence"]["payment_attestation"].merge!(change)
      capture("payment_evidence_pending")
      expect(verifier.verified?(disposition, current)).to be(false)
    end
  end

  it "accepts denied work only as not payable and zero hours only with zero-hours evidence" do
    current["state"]["approval_status"] = "denied"
    current["lifecycle"]["status"] = "not_payable"
    capture("not_payable")
    expect(verifier.verified?(disposition, current)).to be(true)
    capture("no_payable_hours")
    expect(verifier.verified?(disposition, current)).to be(false)
    current["hours"] = 0
    capture("no_payable_hours")
    expect(verifier.verified?(disposition, current)).to be(true)
  end

  context "with an authenticated immutable manual baseline" do
    let(:run) { create(:pay_period, :committed, company: company, start_date: "2026-09-01", end_date: "2026-09-15", pay_date: "2026-09-30") }
    let(:line) do
      { "batch_id" => "AIRE-HISTORY-SYNTHETIC", "batch_checksum" => "b" * 64,
        "batch_start_date" => "2026-09-01", "batch_end_date" => "2026-09-15",
        "processing" => { "status" => "committed", "external_system" => "cornerstone_payroll_manual", "external_pay_period_id" => run.id.to_s },
        "source_time_entry_id" => "1804", "source_user_uuid" => uuid, "source_time_entry_version" => 2,
        "line_key" => "admin", "source_kind" => "current", "work_date" => "2026-09-15", "category" => current["category"],
        "total_hours" => "4.25", "regular_hours" => "4.25", "overtime_hours" => "0.0", "current_content_matches" => true, "processing_conflict" => false }
    end
    let(:payload) do
      { "batch_id" => line["batch_id"], "start_date" => line["batch_start_date"], "end_date" => line["batch_end_date"],
        "export" => { "checksum" => line["batch_checksum"] }, "employees" => [ { "source_user_uuid" => uuid,
          "adjustments" => [ line.slice("source_time_entry_id", "source_time_entry_version", "line_key", "source_kind", "category",
            "total_hours", "regular_hours", "overtime_hours").merge("original_work_date" => line["work_date"]) ] } ] }
    end

    before do
      current["state"]["approval_status"] = "approved"
      current["lifecycle"]["status"] = "committed"
      current["history_evidence"]["baseline_lines"] = [ line ]
      allow(client).to receive(:payroll_batch).with(batch_id: line["batch_id"]).and_return(payload)
      validator = instance_double(TimeTracking::PayrollBatchPayloadValidator, validate!: payload)
      allow(TimeTracking::PayrollBatchPayloadValidator).to receive(:new).and_return(validator)
      capture("historical_baseline")
    end

    it "verifies frozen lines against authenticated batch content and the company-owned committed run" do
      expect(verifier.verified?(disposition, current)).to be(true)
      expect(client).to have_received(:payroll_batch).once
    end

    it "retains baseline provenance for a represented pending source without approving it" do
      current["state"]["approval_status"] = nil
      capture("pending_review")
      expect(verifier.verified?(disposition, current)).to be(true)
    end

    it "rejects another company's run or an uncommitted run" do
      run.update_column(:company_id, create(:company).id)
      expect(verifier.verified?(disposition, current)).to be(false)
    end

    %w[batch_checksum source_user_uuid source_time_entry_id work_date total_hours regular_hours current_content_matches].each do |field|
      it "rejects altered baseline #{field}, even when the manifest repeats it" do
        line[field] = field == "current_content_matches" ? false : "changed"
        capture("historical_baseline")
        expect(verifier.verified?(disposition, current)).to be(false)
      end
    end

    it "rejects partial or overlapping duplicate lines" do
      line["total_hours"] = "2"
      capture("historical_baseline")
      expect(verifier.verified?(disposition, current)).to be(false)
      line["total_hours"] = "4.25"
      current["history_evidence"]["baseline_lines"] << line.deep_dup
      capture("historical_baseline")
      expect(verifier.verified?(disposition, current)).to be(false)
    end

    it "rejects a frozen line whose category differs from the source provenance" do
      payload["employees"].first["adjustments"].first["category"] = nil
      expect(verifier.verified?(disposition, current)).to be(false)
    end
  end
end
