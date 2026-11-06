# frozen_string_literal: true

require "rails_helper"
require "tempfile"
require "rake"

RSpec.shared_context "aire history approval evidence" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:uuid) { SecureRandom.uuid }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services", cutoff_enforcement_starts_on: "2026-08-16",
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
        "payable_segments" => [ { "work_date" => "2026-08-14", "total_hours" => "6.1" } ],
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
        "time_entries" => (@inventory || [ row ]), "pagination" => { "current_page" => 1, "per_page" => 50, "total_count" => (@inventory || [ row ]).length, "total_pages" => 1, "truncated" => false } }
    end
  end

  def rollout(packet)
    TimeTracking::VerifiedHistoryRollout.new(manifest: packet, actor: actor)
  end

  before do
    allow(client).to receive(:payroll_cockpit_employees).and_return(
      "employees" => [ { "id" => "91", "payroll_integration_id" => uuid, "full_name" => employee.full_name, "email" => employee.email, "active" => true } ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false })
  end

  def history_service(user = actor)
    TimeTracking::HistoryApproval.new(source: source, actor: user)
  end

  def approve_review(page, **options)
    history_service.approve!(review: AireHistoryReview.find(page.fetch("review_id")), digest: page.fetch("digest"),
      attestation: TimeTracking::HistoryApproval::ATTESTATION, **options)
  end
end
