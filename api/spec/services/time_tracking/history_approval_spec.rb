# frozen_string_literal: true

require "rails_helper"
require "support/aire_history_approval_evidence"

RSpec.describe TimeTracking::HistoryApproval do
  include_context "aire history approval evidence"

  def frozen_whole_overtime!
    row["hours"] = 0.3
    row["state"]["overtime_status"] = "pending"
    row["history_evidence"]["baseline_lines"] = []
    hold = { "source_time_entry_id" => "41", "source_user_id" => "91", "source_user_uuid" => uuid,
      "original_work_date" => row["work_date"], "category" => category, "reason" => "pending_overtime",
      "held_total_hours" => "0.3", "held_regular_hours" => "0.0", "held_overtime_hours" => "0.3" }
    payload["employees"] = []
    payload["exclusions"] = [ hold ]
    payload["summary"].merge!("employee_count" => 0, "adjustment_count" => 0, "exclusion_count" => 1, "total_hours" => 0,
      "regular_hours" => 0, "overtime_hours" => 0, "current_count" => 0)
    payload["issues"]["pending_overtime_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["history_evidence"]["pending_overtime"] = { "kind" => "pending_overtime", "source_time_entry_version" => 2,
      "payable_content_checksum" => row.dig("history_evidence", "payable_content_checksum"), "represented_regular_hours" => "0.0",
      "batch_id" => payload["batch_id"], "batch_checksum" => payload.dig("export", "checksum"), "frozen_exclusion" => hold }
  end

  it "prefills a strict baseline and exact signed rounding acknowledgement without applying anything" do
    expect(client).to receive(:payroll_batch).once.and_return(payload)
    page = history_service.prepare!
    expect(page).to include("history_coverage_verified" => true, "approved_at" => nil)
    expect(page["dispositions"]).to include(include("type" => "historical_baseline", "count" => 1, "hours" => "6.1"))
    expect(page["rounding_variances"].sole).to include("source_total" => "6.1", "paid_total" => "6.13", "signed_difference" => "0.03")
    expect(page["mappings"].sole).to include("existing" => true, "confirmation_required" => false)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(CheckEvent.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end

  it "applies accounting coverage and fresh completion atomically with the actor, time, attestation and digest" do
    page = history_service.prepare!
    result = approve_review(page)
    review = AireHistoryReview.find(page["review_id"])
    expect(result["approved_at"]).to be_present
    expect(review).to have_attributes(actor: actor, attestation: described_class::ATTESTATION)
    expect(review.receipt).to have_attributes(coverage_verified: true, approved_by: actor)
    expect(TimeTracking::CanonicalPayload.checksum(review.approved_packet)).to eq(review.receipt.manifest_sha256)
    expect(source.historical_reconciliation_complete?).to be(true)
    expect(AuditLog.find_by!(action: "aire_history#approved").metadata).to include("summary_digest" => page["digest"])
    expect(CheckEvent.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
    expect(TimeTrackingEntryAllocation.count).to eq(0)
    expect(AirePayrollCalendarPeriod.count).to eq(0)
    expect(AirePayrollAcknowledgement.count).to eq(0)
  end

  it "rolls back the receipt, mappings and audit if fresh ensure_complete refuses" do
    source.time_tracking_employee_mappings.delete_all
    page = history_service.prepare!
    allow_any_instance_of(TimeTracking::VerifiedHistoryRollout).to receive(:ensure_complete!)
      .and_raise(TimeTracking::VerifiedHistoryRollout::Error, "Fresh coverage changed")
    expect { approve_review(page) }.to raise_error(TimeTracking::VerifiedHistoryRollout::Error, /Fresh coverage/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(AireHistoryReview.find(page["review_id"]).approved_at).to be_nil
    expect(AuditLog.where(action: "aire_history#approved")).not_to exist
    expect(source.time_tracking_employee_mappings).not_to exist
  end

  it "returns an existing approval after a lost response and prevents a second draft from approving" do
    first = history_service.prepare!
    second = history_service.prepare!
    approve_review(first)
    expect(history_service.prepare!).to include("review_id" => first["review_id"], "approved_at" => be_present)
    expect { approve_review(second) }.to raise_error(described_class::Error, /Another summary/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(1)
  end

  it "protects approved review evidence at both the model and database layers" do
    page = history_service.prepare!
    approve_review(page)
    review = AireHistoryReview.find(page["review_id"])
    expect { review.update!(attestation: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect do
      AireHistoryReview.transaction(requires_new: true) { AireHistoryReview.where(id: review.id).update_all(attestation: "changed") }
    end.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    expect do
      AireHistoryReview.transaction(requires_new: true) { ActiveRecord::Base.connection.execute("TRUNCATE aire_history_reviews") }
    end.to raise_error(ActiveRecord::StatementInvalid, /cannot be truncated/)
  end

  it "reports the exact source entry that changed and applies nothing" do
    page = history_service.prepare!
    row["version"] += 1
    expect { approve_review(page) }.to raise_error(described_class::Changed, /AIRE entries 41 changed/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(AireHistoryReview.find(page["review_id"]).approved_at).to be_nil
  end

  it "rejects committed register drift including unchanged totals" do
    page = history_service.prepare!
    item.update_column(:updated_at, item.updated_at + 1.second)
    expect { approve_review(page) }.to raise_error(described_class::Changed, /Payroll runs.*changed/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "rejects an unacknowledgeable 0.06 hour difference" do
    item.update_column(:hours_worked, 6.16)
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(false)
    expect(page["rounding_variances"].sole).to include("signed_difference" => "0.06", "within_limit" => false)
    expect { approve_review(page) }.to raise_error(described_class::Error, /coverage is incomplete/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "defaults an unsupported approved source to pending review but refuses to certify false coverage" do
    row["history_evidence"]["baseline_lines"] = []
    page = history_service.prepare!
    expect(page["pending_review"].sole).to include("id" => "41", "disposition" => "pending_review")
    expect(page["history_coverage_verified"]).to be(false)
    expect { approve_review(page) }.to raise_error(described_class::Error, /coverage is incomplete/)
  end

  it "preserves NULL-approval pending work and the exact owed 1804 case without payment or time approval" do
    pending = row.deep_dup.merge("id" => "42", "hours" => 2.0, "state" => { "status" => "completed", "approval_status" => nil })
    pending["history_evidence"]["baseline_lines"] = []
    owed = pending.deep_dup.merge("id" => "1804", "hours" => 4.25, "state" => { "status" => "completed", "approval_status" => "approved" },
      "lifecycle" => { "status" => "ready_for_cutoff" })
    owed["history_evidence"]["active_cases"] = [ { "version" => 2, "source_user_uuid" => uuid, "status" => "open", "held_total_hours" => 4.25 } ]
    @inventory = [ row, pending, owed ]
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(true)
    expect(page["owed"].sole).to include("id" => "1804", "hours" => "4.25")
    expect(page["pending_review"].sole).to include("id" => "42", "approval_status" => nil)
    approve_review(page)
    expect(AireHistoryReview.find(page["review_id"]).approved_packet["reviewed_dispositions"].map { |record| record["disposition"] })
      .to eq(%w[historical_baseline pending_review owed])
    expect(TimeTrackingManualAllocation.count).to eq(0)
    expect(CheckEvent.count).to eq(0)
  end

  [ "not_payable", "no_payable_hours", "payment_evidence_pending" ].each do |type|
    it "prefills the strict #{type} disposition without converting it to a paid or approved entry" do
      row["history_evidence"]["baseline_lines"] = []
      case type
      when "not_payable"
        row["state"]["approval_status"] = "denied"
        row["lifecycle"] = { "status" => "not_payable" }
      when "no_payable_hours"
        row["hours"] = 0
      when "payment_evidence_pending"
        row["history_evidence"]["payment_attestation"] = { "id" => 7, "source_changed" => false, "hours" => row["hours"] }
        row["lifecycle"] = { "status" => "payment_attested_pending_evidence" }
      end
      state = row.fetch("state").deep_dup
      page = history_service.prepare!
      expect(page["dispositions"].sole).to include("type" => type)
      expect(page["history_coverage_verified"]).to be(true)
      approve_review(page)
      expect(row.fetch("state")).to eq(state)
      expect(CheckEvent.count).to eq(0)
      expect(TimeTrackingManualAllocation.count).to eq(0)
    end
  end

  it "shows only the exact frozen pending-OT remainder beside represented regular history" do
    row["hours"] = 6.4
    row["state"]["overtime_status"] = "pending"
    row["history_evidence"]["payable_segments"].sole["total_hours"] = "6.4"
    payload["exclusions"] = [ { "source_time_entry_id" => "41", "source_user_id" => "91", "source_user_uuid" => uuid,
      "original_work_date" => row["work_date"], "category" => category, "reason" => "pending_overtime",
      "held_total_hours" => "0.3", "held_regular_hours" => "0.0", "held_overtime_hours" => "0.3" } ]
    payload["summary"]["exclusion_count"] = 1
    payload["issues"]["pending_overtime_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["history_evidence"]["baseline_lines"].sole["batch_checksum"] = payload.dig("export", "checksum")
    page = history_service.prepare!
    expect(page["dispositions"].sole).to include("type" => "historical_baseline_pending_overtime", "hours" => "6.4")
    expect(page["pending_review"].sole).to include("hours" => "0.3")
    expect(page["history_coverage_verified"]).to be(true)
    approve_review(page)
    expect(row.dig("state", "overtime_status")).to eq("pending")
  end

  it "keeps a whole frozen overtime exclusion pending when no regular lines were represented" do
    frozen_whole_overtime!
    page = history_service.prepare!
    expect(page["dispositions"].sole).to include("type" => "pending_overtime")
    expect(page["history_coverage_verified"]).to be(true)
    approve_review(page)
    expect(CheckEvent.count).to eq(0)
  end

  it "suggests an exact directory/Payroll match and only saves it on approval" do
    source.time_tracking_employee_mappings.delete_all
    page = history_service.prepare!
    expect(page["mappings"].sole).to include("employee_id" => employee.id, "existing" => false, "confirmation_required" => false)
    expect(page["history_coverage_verified"]).to be(true)
    expect(source.time_tracking_employee_mappings).not_to exist
    approve_review(page)
    expect(source.time_tracking_employee_mappings.find_by!(source_user_uuid: uuid).employee_id).to eq(employee.id)
  end

  it "never infers debt from a legacy case for verified frozen pending overtime" do
    frozen_whole_overtime!
    row["state"]["overtime_status"] = "none"
    row["lifecycle"] = { "status" => "ready_for_cutoff" }
    row["history_evidence"]["active_cases"] = [ { "id" => "synthetic-legacy-case", "version" => 2,
      "source_user_uuid" => uuid, "status" => "open", "destination_kind" => "unassigned", "held_total_hours" => "0.3" } ]
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(false)
    expect(page["owed"]).to be_empty
    expect(page["pending_review"].sole).to include("id" => "41", "hours" => "0.3")
    expect { approve_review(page) }.to raise_error(described_class::Error, /coverage is incomplete/)
    expect(CheckEvent.count).to eq(0)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "upgrades a verified numeric legacy mapping only during approval without inserting a duplicate person" do
    mapping = source.time_tracking_employee_mappings.sole
    mapping.update!(source_user_uuid: nil)
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(true)
    expect(page["mappings"].sole).to include("employee_id" => employee.id, "existing" => false)
    expect(mapping.reload.source_user_uuid).to be_nil
    approve_review(page)
    expect(mapping.reload.source_user_uuid).to eq(uuid)
    expect(source.time_tracking_employee_mappings.count).to eq(1)
  end

  it "requires explicit confirmation of a nonexact mapping and rolls all changes back on refusal" do
    source.time_tracking_employee_mappings.delete_all
    employee.update!(last_name: "Different")
    allow(client).to receive(:payroll_cockpit_employees).and_return(
      "employees" => [ { "id" => "91", "payroll_integration_id" => uuid, "full_name" => "Source person", "email" => "source@example.test" } ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false })
    page = history_service.prepare!(mapping_selections: [ { "source_user_uuid" => uuid, "employee_id" => employee.id } ])
    expect(page["mappings"].sole["confirmation_required"]).to be(true)
    expect { approve_review(page) }.to raise_error(described_class::Error, /Explicitly confirm/)
    expect(source.time_tracking_employee_mappings).not_to exist
    expect(approve_review(page, confirmed_mapping_uuids: [ uuid ])["approved_at"]).to be_present
  end

  it "does not erase accents or punctuation to classify different names as an exact employee match" do
    source.time_tracking_employee_mappings.delete_all
    employee.update!(first_name: "José", last_name: "Person", email: nil)
    allow(client).to receive(:payroll_cockpit_employees).and_return(
      "employees" => [ { "id" => "91", "payroll_integration_id" => uuid, "full_name" => "Jos Person", "email" => nil } ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false })
    page = history_service.prepare!(mapping_selections: [ { "source_user_uuid" => uuid, "employee_id" => employee.id } ])
    expect(page["mappings"].sole["confirmation_required"]).to be(true)
    expect { approve_review(page) }.to raise_error(described_class::Error, /Explicitly confirm/)
  end

  it "blocks a saved numeric owner mismatch instead of trusting its permanent UUID alone" do
    source.time_tracking_employee_mappings.sole.update!(source_user_id: "92")
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(false)
    expect { approve_review(page) }.to raise_error(described_class::Error, /coverage is incomplete/)
  end

  it "refuses a directory UUID change" do
    page = history_service.prepare!
    allow(client).to receive(:payroll_cockpit_employees).and_return("employees" => [],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 0, "total_pages" => 1, "truncated" => false })
    expect { approve_review(page) }.to raise_error(described_class::Changed, /directory changed/)
  end

  it "permits an assigned accountant but never a manager or a revoked assignment" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    assignment = CompanyAssignment.find_or_create_by!(company: company, user: accountant)
    expect(described_class.allowed?(accountant, company)).to be(true)
    assignment.update!(expires_at: 1.minute.ago)
    expect(described_class.allowed?(accountant, company)).to be(false)
    expect(described_class.allowed?(create(:user, company: company, role: "manager"), company)).to be(false)
  end

  it "refuses missing attestation, wrong digest, another actor and expired summaries" do
    page = history_service.prepare!
    review = AireHistoryReview.find(page["review_id"])
    expect { history_service.approve!(review: review, digest: page["digest"], attestation: "yes") }.to raise_error(described_class::Error, /Tick/)
    expect { history_service.approve!(review: review, digest: "a" * 64, attestation: described_class::ATTESTATION) }.to raise_error(described_class::Error, /different/)
    review.update_column(:created_at, 2.hours.ago)
    expect { approve_review(page) }.to raise_error(described_class::Error, /expired/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "refuses any prepared or published calendar" do
    page = history_service.prepare!
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: run)
    expect { approve_review(page) }.to raise_error(described_class::Error, /before any calendar/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "does not let an open Solo earning decision block pending history approval" do
    row["category"] = { "id" => "3", "key" => "solo", "name" => "Solo" }
    row["state"]["approval_status"] = nil
    row["history_evidence"]["baseline_lines"] = []
    page = history_service.prepare!
    expect(page["history_coverage_verified"]).to be(true)
    expect(page["solo_decisions"].sole).to include("employee_id" => employee.id, "hours" => "6.1")
    approve_review(page)
    expect(TimeTrackingEarningChoice.count).to eq(0)
  end

  it "never guesses a Solo or Solo Hours earning rate from a matching label" do
    rate = create(:employee_wage_rate, employee: employee, label: "Solo", rate: 12.34)
    instance = TimeTracking::BatchImportPreviewService.new(pay_period: run, source: source)
    category = { key: "solo_hours", name: "Solo Hours" }
    expect(instance.send(:find_wage_rate, category, [ rate ], employee_id: employee.id)).to eq([ nil, nil ])
    TimeTrackingEarningChoice.create!(time_tracking_source: source, employee: employee, employee_wage_rate: rate,
      reviewed_by: actor, source_category_key: "solo", rate_snapshot: rate.attributes.slice("id", "employee_id", "label", "rate", "active").as_json)
    expect(instance.send(:find_wage_rate, category, [ rate ], employee_id: employee.id)).to eq([ rate, "accountant_choice" ])
    rate.update!(rate: 12.35)
    expect(instance.send(:find_wage_rate, category, [ rate ], employee_id: employee.id)).to eq([ nil, nil ])
  end

  context "with authenticated legacy frozen evidence" do
    before do
      line = row["history_evidence"]["baseline_lines"].sole
      line.merge!("current_content_matches" => false, "source_time_entry_version" => nil,
        "source_user_id" => "91", "identity_basis" => "reviewed_legacy_owner", "snapshot_checksum" => "c" * 64,
        "legacy_frozen_evidence" => {
          "kind" => "legacy_frozen_batch_baseline", "evidence_strength" => "retained_snapshot_and_unchanged_source",
          "eligible" => true, "blockers" => [], "payload_checksum_verified" => true,
          "batch_finalized_at" => payload["cutoff_at"], "source_created_at" => "2026-08-14T00:00:00Z",
          "source_updated_at" => "2026-08-15T00:00:00Z", "source_version" => 2,
          "source_user_id" => "91", "source_user_uuid" => uuid, "later_edit_audit_count" => 0,
          "retained_snapshot_fields" => %w[user_id work_date hours time_category],
          "source_observation_checksum" => "d" * 64, "revision_observation_checksum" => "e" * 64
        })
      payload["export"]["finalized_at_precise"] = payload["cutoff_at"]
      payload["employees"].sole["source_user_uuid"] = nil
      payload["employees"].sole["adjustments"].sole["source_time_entry_version"] = nil
      payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
      line["batch_checksum"] = payload.dig("export", "checksum")
      row["state"]["approval_status"] = nil
    end

    it "prefills the lower-strength legacy type using the real payload validator and preserves NULL approval" do
      page = history_service.prepare!
      expect(page["dispositions"].sole).to include("type" => "legacy_frozen_batch_baseline")
      expect(page["pending_review"].sole).to include("id" => "41", "approval_status" => nil, "disposition" => "legacy_frozen_batch_baseline")
      expect(page["history_coverage_verified"]).to be(true)
      approve_review(page)
      expect(AireHistoryReview.find(page["review_id"]).approved_packet["reviewed_dispositions"].sole.dig("source", "state", "approval_status")).to be_nil
    end

    it "keeps changed or tampered legacy evidence blocking" do
      row["history_evidence"]["baseline_lines"].sole["legacy_frozen_evidence"].merge!("eligible" => false, "blockers" => [ "snapshot_mismatch" ])
      page = history_service.prepare!
      expect(page["history_coverage_verified"]).to be(false)
      expect { approve_review(page) }.to raise_error(described_class::Error, /coverage is incomplete/)
    end
  end

  it "stores only an explicit real employee earning choice and rejects stale or foreign rates" do
    row["category"] = { "id" => "3", "key" => "solo", "name" => "Solo" }
    row["state"]["approval_status"] = nil
    row["history_evidence"]["baseline_lines"] = []
    other = create(:employee, company: company)
    foreign_rate = create(:employee_wage_rate, employee: other, rate: 9)
    page = history_service.prepare!
    expect { approve_review(page, solo_choices: [ { "employee_id" => employee.id, "employee_wage_rate_id" => foreign_rate.id } ]) }
      .to raise_error(described_class::Error, /no longer available/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    rate = create(:employee_wage_rate, employee: employee, label: "Client approved component", rate: 12.34)
    page = history_service.prepare!
    approve_review(page, solo_choices: [ { "employee_id" => employee.id, "employee_wage_rate_id" => rate.id } ])
    choice = TimeTrackingEarningChoice.sole
    expect(choice.current_rate).to eq(rate)
    rate.update!(rate: 12.35)
    expect(choice.reload.current_rate).to be_nil
  end

  it "rejects an earning choice for a mapped person without an attested Solo item" do
    rate = create(:employee_wage_rate, employee: employee, label: "Explicit component", rate: 12)
    page = history_service.prepare!
    expect(page["solo_decisions"]).to be_empty
    expect { approve_review(page, solo_choices: [ { "employee_id" => employee.id, "employee_wage_rate_id" => rate.id } ]) }
      .to raise_error(described_class::Error, /Solo history on this summary/)
    expect(TimeTrackingEarningChoice.count).to eq(0)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "rolls back when the bounded business-lock phase exceeds its deadline" do
    page = history_service.prepare!
    stub_const("TimeTracking::HistoryApproval::LOCK_BUDGET_SECONDS", 0.05)
    allow_any_instance_of(TimeTracking::VerifiedHistoryRollout).to receive(:ensure_complete!).and_wrap_original do |method|
      sleep 0.1
      method.call
    end
    expect { approve_review(page) }.to raise_error(described_class::LockBudgetExceeded, /Nothing was applied/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(AireHistoryReview.find(page["review_id"]).approved_at).to be_nil
    expect(AuditLog.where(action: "aire_history#approved")).not_to exist
  end

  it "rechecks Payroll state after waiting for approval locks" do
    service = history_service
    page = service.prepare!
    allow(service).to receive(:with_approval_locks).and_wrap_original do |method, review, &block|
      method.call(review) do
        employee.update!(first_name: "Changed")
        block.call
      end
    end
    expect { service.approve!(review: AireHistoryReview.find(page["review_id"]), digest: page["digest"], attestation: page["attestation"]) }
      .to raise_error(described_class::Changed, /Payroll employees changed/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end
  it "prefills the authenticated prior policy and atomically approves complete coverage without new pay" do
    item.update_columns(hours_worked: 8, overtime_hours: 2)
    adjustment.merge!("total_hours" => 10.0, "regular_hours" => 10.0)
    payload["employees"].sole.merge!("total_hours" => 10.0, "regular_hours" => 10.0)
    payload["summary"].merge!("total_hours" => 10.0, "regular_hours" => 10.0)
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    row["hours"] = 10.0
    row["history_evidence"]["payable_segments"].sole["total_hours"] = "10.0"
    row["history_evidence"]["baseline_lines"].sole.merge!("total_hours" => 10.0, "regular_hours" => 10.0,
      "batch_checksum" => payload.dig("export", "checksum"), "snapshot_checksum" => "f" * 64, "source_user_id" => "91")
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
    page = history_service.prepare!
    expect(page).to include("history_coverage_verified" => true)
    expect(page["dispositions"].sole["type"]).to eq("paid_under_prior_daily_weekly_ot_policy")
    expect(page["historical_policies"].sole).to include("paid_split" => { "regular_hours" => "8.0", "overtime_hours" => "2.0" })
    original = payload["export"]["prior_overtime_policy"].deep_dup
    reads = 0
    allow(client).to receive(:payroll_batch) do
      answer = payload.deep_dup
      reads += 1
      if reads == 1
        changed = payload["export"]["prior_overtime_policy"]
        changed["threshold_evidence"]["observation"] = "Historical threshold observation changed during capture"
        changed["evidence_checksum"] = TimeTracking::CanonicalPayload.checksum(changed.except("evidence_checksum"))
      end
      answer
    end
    expect { approve_review(page) }.to raise_error(TimeTracking::HistoryApproval::Changed)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    payload["export"]["prior_overtime_policy"] = original
    allow(client).to receive(:payroll_batch).and_return(payload)
    expect { approve_review(page) }.to change(AireVerifiedHistoryRolloutReceipt, :count).by(1)
      .and change(CheckEvent, :count).by(0).and change(TimeTrackingManualAllocation, :count).by(0)
    expect(AireHistoryReview.find(page["review_id"]).approved_packet["reviewed_dispositions"].sole["prior_overtime_policy"]).to be_present
  end
end
