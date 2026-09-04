# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ApplyImportService, "finalized AIRE batches" do
  def setup_records
    company = create(:company)
    workweek = CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: create(:user, company: company),
      confirmed_at: Time.current,
      notes: "Confirmed for finalized batch tests",
      effective_on: Date.new(2020, 1, 1)
    )
    pay_period = create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 4)
    )
    source = TimeTrackingSource.create!(
      company: company,
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
    [ company, pay_period, source ]
  end

  def payload_for(pay_period:, employee:, adjustments:, batch_id: "AIRE-PAY-APPLY-001")
    total = adjustments.sum { |row| row.fetch("total_hours") }
    regular = adjustments.sum { |row| row.fetch("regular_hours") }
    overtime = adjustments.sum { |row| row.fetch("overtime_hours") }
    employees = adjustments.empty? ? [] : [
      {
        "source_user_id" => "aire-user-1",
        "email" => employee&.email,
        "display_name" => employee&.full_name,
        "adjustments" => adjustments,
        "total_hours" => total,
        "regular_hours" => regular,
        "overtime_hours" => overtime
      }
    ]
    payload = {
      "schema_version" => "2.0",
      "source" => "aire_services",
      "batch_id" => batch_id,
      "start_date" => pay_period.start_date.iso8601,
      "end_date" => pay_period.end_date.iso8601,
      "cutoff_at" => "2026-08-31T01:00:00Z",
      "generated_at" => "2026-08-31T01:00:00Z",
      "employees" => employees,
      "exclusions" => [],
      "issues" => {
        "missing_category_count" => 0,
        "negative_adjustment_count" => adjustments.count { |row| row.values_at("regular_hours", "overtime_hours").any?(&:negative?) },
        "pending_approval_count" => 0,
        "denied_approval_count" => 0,
        "open_clock_count" => 0,
        "pending_overtime_count" => 0,
        "denied_overtime_count" => 0
      },
      "summary" => {
        "employee_count" => employees.size,
        "adjustment_count" => adjustments.size,
        "exclusion_count" => 0,
        "total_hours" => total,
        "regular_hours" => regular,
        "overtime_hours" => overtime,
        "current_count" => adjustments.count { |row| row["source_kind"] == "current" },
        "carryover_count" => adjustments.count { |row| row["source_kind"] == "carryover" },
        "correction_count" => adjustments.count { |row| row["source_kind"] == "correction" }
      }
    }
    payload["export"] = {
      "id" => batch_id,
      "batch_id" => batch_id,
      "readiness_status" => "finalized",
      "cutoff_at" => payload["cutoff_at"],
      "finalized_at" => "2026-08-31T01:00:01Z",
      "checksum_algorithm" => "SHA-256",
      "checksum_scope" => "payload_without_export",
      "checksum" => TimeTracking::CanonicalPayload.checksum(payload)
    }
    payload
  end

  def preview_import(pay_period:, source:, payload:)
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [
        {
          "id" => payload["batch_id"],
          "start_date" => payload["start_date"],
          "end_date" => payload["end_date"],
          "cutoff_at" => payload["cutoff_at"],
          "checksum" => payload.dig("export", "checksum")
        }
      ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)
    TimeTracking::BatchImportPreviewService.new(pay_period: pay_period, source: source).call
  end

  it "requires a written acknowledgement and calculates a correction with Cornerstone's wage rate" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    new_rate = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    adjustments = [
      {
        "source_time_entry_id" => "101",
        "line_key" => "flight:2000",
        "source_kind" => "correction",
        "original_work_date" => "2026-08-17",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => -2.0,
        "regular_hours" => -2.0,
        "overtime_hours" => 0.0
      },
      {
        "source_time_entry_id" => "101",
        "line_key" => "flight:2500",
        "source_kind" => "correction",
        "original_work_date" => "2026-08-17",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 10.0,
        "regular_hours" => 10.0,
        "overtime_hours" => 0.0
      }
    ]
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))
    actor = create(:user, company: company)

    expect do
      described_class.new(import: import, mappings: [], applied_by: actor).call
    end.to raise_error(ArgumentError, /acknowledgement note/)

    results = described_class.new(
      import: import,
      mappings: [
        {
          source_user_id: "aire-user-1",
          employee_id: employee.id,
          include: true,
          wage_rate_mappings: [
            {
              source_category_id: "flight",
              source_category_key: "flight_hours",
              source_category_name: "Flight Hours",
              employee_wage_rate_id: new_rate.id
            }
          ]
        }
      ],
      applied_by: actor,
      acknowledge_negative_adjustments: true,
      negative_adjustment_note: "Verified the old-rate reversal and replacement."
    ).call

    expect(results[:errors]).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item).to have_attributes(hours_worked: 8.0, overtime_hours: 0.0)
    expect(item.wage_rate_hours).to contain_exactly(
      include("employee_wage_rate_id" => new_rate.id, "regular_hours" => 8.0, "rate" => 25.0, "label" => /AIRE correction for Aug 17, 2026 · \$25\.00/)
    )
    expect(import.reload).to have_attributes(
      status: "applied",
      applied_by: actor,
      negative_adjustment_acknowledgement: "Verified the old-rate reversal and replacement."
    )
    expect(item.import_source).to include(import.external_batch_id)
  end

  it "keeps current and carried-forward hours separate on earning lines" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    rate = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    adjustments = [
      {
        "source_time_entry_id" => "101",
        "line_key" => "flight:2500",
        "source_kind" => "current",
        "original_work_date" => "2026-08-20",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      },
      {
        "source_time_entry_id" => "88",
        "line_key" => "flight:2500",
        "source_kind" => "carryover",
        "original_work_date" => "2026-08-14",
        "original_week_start" => "2026-08-09",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 3.5,
        "regular_hours" => 3.5,
        "overtime_hours" => 0.0
      }
    ]
    payload = payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments)
    source_user_uuid = SecureRandom.uuid
    payload.fetch("employees").first["source_user_uuid"] = source_user_uuid
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    import = preview_import(pay_period: pay_period, source: source, payload: payload)

    results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

    expect(results[:errors]).to be_empty
    expect(pay_period.payroll_items.find_by!(employee: employee).wage_rate_hours).to contain_exactly(
      include("employee_wage_rate_id" => rate.id, "regular_hours" => 8.0, "label" => /AIRE current period/),
      include("employee_wage_rate_id" => rate.id, "regular_hours" => 3.5, "label" => /AIRE carryover from Aug 14, 2026/)
    )
    expect(import.time_tracking_entry_allocations.order(:source_time_entry_id)).to contain_exactly(
      have_attributes(source_time_entry_id: "101", source_user_uuid: source_user_uuid, source_kind: "current", total_hours: 8.0),
      have_attributes(source_time_entry_id: "88", source_user_uuid: source_user_uuid, source_kind: "carryover", total_hours: 3.5)
    )
    expect(import.aire_payroll_entry_acknowledgements.pluck(:status, :source_time_entry_id)).to contain_exactly(
      [ "imported", "101" ],
      [ "imported", "88" ]
    )
  end

  it "links an exact committed historical payroll without recalculating its amounts" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "historical@example.com")
    adjustments = [
      {
        "source_time_entry_id" => "historic-101",
        "line_key" => "flight-current",
        "source_kind" => "current",
        "original_work_date" => "2026-08-20",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      }
    ]
    payload = payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments, batch_id: "AIRE-PAY-HISTORICAL-001")
    source_user_uuid = SecureRandom.uuid
    payload.fetch("employees").first["source_user_uuid"] = source_user_uuid
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    import = preview_import(pay_period: pay_period, source: source, payload: payload)
    item = create(:payroll_item, pay_period: pay_period, employee: employee, hours_worked: 8.0, overtime_hours: 0.0, gross_pay: 200.0, net_pay: 180.0)
    committed_at = Time.zone.parse("2026-09-01 09:00:00")
    pay_period.update!(status: "committed", committed_at: committed_at)
    employee.update!(status: "terminated")
    actor = create(:user, company: company)

    result = TimeTracking::ReconcileCommittedImportService.new(
      import: import,
      mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id } ],
      reconciled_by: actor,
      reconciliation_note: "Matched against the signed historical payroll register."
    ).call

    expect(result.fetch(:errors)).to be_empty
    expect(item.reload).to have_attributes(hours_worked: 8.0, overtime_hours: 0.0, gross_pay: 200.0, net_pay: 180.0)
    expect(import.reload).to have_attributes(status: "applied", reconciled_by: actor)
    expect(import.reconciliation_note).to match(/signed historical payroll register/)
    expect(result.fetch(:rounding_exceptions)).to be_empty
    expect(import.reconciliation_exceptions).to be_empty
    expect(import.time_tracking_entry_allocations).to contain_exactly(
      have_attributes(source_time_entry_id: "historic-101", source_user_uuid: source_user_uuid, payroll_item_id: item.id)
    )
    expect(import.aire_payroll_entry_acknowledgements.pluck(:status, :source_time_entry_id)).to contain_exactly(
      [ "committed", "historic-101" ]
    )
  end

  it "records a small legacy rounding exception without changing committed payroll amounts" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "rounding@example.com")
    adjustment = {
      "source_time_entry_id" => "historic-rounding",
      "line_key" => "flight-current",
      "source_kind" => "current",
      "original_work_date" => "2026-08-20",
      "original_week_start" => "2026-08-16",
      "source_category_id" => "flight",
      "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
      "total_hours" => 8.0,
      "regular_hours" => 8.0,
      "overtime_hours" => 0.0
    }
    import = preview_import(
      pay_period: pay_period,
      source: source,
      payload: payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ], batch_id: "AIRE-PAY-HISTORICAL-ROUNDING")
    )
    item = create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      hours_worked: 7.97,
      overtime_hours: 0.03,
      gross_pay: 200.0,
      net_pay: 180.0
    )
    pay_period.update!(status: "committed", committed_at: Time.current)

    result = TimeTracking::ReconcileCommittedImportService.new(
      import: import,
      mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id } ],
      reconciled_by: create(:user, company: company),
      reconciliation_note: "Owner accepted the documented legacy rounding difference."
    ).call

    expected_exception = {
      "source_user_id" => "aire-user-1",
      "employee_id" => employee.id,
      "employee_name" => employee.full_name,
      "aire_regular_hours" => "8.00",
      "cornerstone_regular_hours" => "7.97",
      "regular_difference_hours" => "-0.03",
      "aire_overtime_hours" => "0.00",
      "cornerstone_overtime_hours" => "0.03",
      "overtime_difference_hours" => "+0.03",
      "total_difference_hours" => "+0.00"
    }
    expect(result.fetch(:rounding_exceptions)).to contain_exactly(expected_exception)
    expect(import.reload.reconciliation_exceptions).to contain_exactly(expected_exception)
    expect(item.reload).to have_attributes(hours_worked: 7.97, overtime_hours: 0.03, gross_pay: 200.0, net_pay: 180.0)
  end

  {
    "printed" => [ "payment_prepared", "printed" ],
    "delivered" => [ "payment_issued", "delivered" ],
    "voided" => [ "payment_voided", "voided" ]
  }.each do |check_status, (payment_status, event_type)|
    it "reconciles #{check_status} payment state using the matching check event timestamp" do
      company, pay_period, source = setup_records
      employee = create(:employee, company: company, department: create(:department, company: company), email: "#{check_status}@example.com")
      adjustment = {
        "source_time_entry_id" => "historic-payment",
        "line_key" => "flight-current",
        "source_kind" => "current",
        "original_work_date" => "2026-08-20",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      }
      import = preview_import(
        pay_period: pay_period,
        source: source,
        payload: payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ], batch_id: "AIRE-PAY-#{check_status.upcase}")
      )
      item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        hours_worked: 8.0,
        overtime_hours: 0.0,
        check_number: "7001",
        check_printed_at: (Time.zone.parse("2026-09-01 08:00:00") unless check_status == "voided"),
        voided: check_status == "voided",
        voided_at: (Time.zone.parse("2026-09-01 11:00:00") if check_status == "voided"),
        void_reason: ("Returned payment was voided" if check_status == "voided")
      )
      state_at = item.check_printed_at
      unless check_status == "printed"
        state_at = Time.zone.parse("2026-09-01 10:00:00")
        event = item.check_events.create!(event_type: event_type, check_number: item.check_number)
        event.update_columns(created_at: state_at, updated_at: state_at)
        unrelated_event = item.check_events.create!(event_type: "renumbered", check_number: "9999")
        unrelated_event.update_columns(created_at: state_at + 1.hour, updated_at: state_at + 1.hour)
      end
      pay_period.update!(status: "committed", committed_at: Time.zone.parse("2026-09-01 09:00:00"))

      TimeTracking::ReconcileCommittedImportService.new(
        import: import,
        mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id } ],
        reconciled_by: create(:user, company: company),
        reconciliation_note: "Matched against the signed historical payroll register."
      ).call

      acknowledgement = import.aire_payroll_entry_acknowledgements.find_by!(status: payment_status)
      expect(acknowledgement).to have_attributes(
        payment_reference: "7001",
        source_event_key: "reconciliation_payment_#{item.id}:#{import.id}:#{payment_status}:#{item.id}:historic-payment"
      )
      expect(acknowledgement.occurred_at).to be_within(1.second).of(state_at)
    end
  end

  it "refuses to reconcile a voided historical pay period" do
    company, pay_period, source = setup_records
    pay_period.update!(status: "committed", correction_status: "voided", committed_at: Time.current)
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source
    )

    expect do
      TimeTracking::ReconcileCommittedImportService.new(
        import: import,
        mappings: [],
        reconciled_by: create(:user, company: company),
        reconciliation_note: "Compared against the signed historical register."
      ).call
    end.to raise_error(ArgumentError, /committed, active pay period/)
  end

  it "refuses to link a historical payroll when employee hours exceed the legacy rounding tolerance" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "mismatch@example.com")
    adjustment = {
      "source_time_entry_id" => "historic-102",
      "line_key" => "flight-current",
      "source_kind" => "current",
      "original_work_date" => "2026-08-20",
      "original_week_start" => "2026-08-16",
      "source_category_id" => "flight",
      "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
      "total_hours" => 8.0,
      "regular_hours" => 8.0,
      "overtime_hours" => 0.0
    }
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ], batch_id: "AIRE-PAY-HISTORICAL-002"))
    create(:payroll_item, pay_period: pay_period, employee: employee, hours_worked: 7.5, overtime_hours: 0.0)
    pay_period.update!(status: "committed", committed_at: Time.current)

    expect do
      TimeTracking::ReconcileCommittedImportService.new(
        import: import,
        mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id } ],
        reconciled_by: create(:user, company: company),
        reconciliation_note: "Investigated against historical payroll register."
      ).call
    end.to raise_error(ArgumentError, /does not reconcile/)
    expect(import.reload.status).to eq("previewed")
    expect(import.time_tracking_entry_allocations).to be_empty
  end

  it "preserves distinct wage mappings for the same category by source kind" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "split-rate@example.com")
    current_rate = create(:employee_wage_rate, employee: employee, label: "Current Flight", rate: 30, is_primary: true, active: true)
    carryover_rate = create(:employee_wage_rate, employee: employee, label: "Prior Flight", rate: 25, is_primary: false, active: true)
    adjustments = [
      {
        "source_time_entry_id" => "101",
        "line_key" => "flight-current",
        "source_kind" => "current",
        "original_work_date" => "2026-08-20",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      },
      {
        "source_time_entry_id" => "88",
        "line_key" => "flight-carryover",
        "source_kind" => "carryover",
        "original_work_date" => "2026-08-14",
        "original_week_start" => "2026-08-09",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 3.5,
        "regular_hours" => 3.5,
        "overtime_hours" => 0.0
      }
    ]
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))
    mappings = [
      {
        source_user_id: "aire-user-1",
        employee_id: employee.id,
        include: true,
        wage_rate_mappings: [
          {
            source_category_id: "flight",
            source_category_key: "flight_hours",
            source_category_name: "Flight Hours",
            source_kind: "current",
            employee_wage_rate_id: current_rate.id
          },
          {
            source_category_id: "flight",
            source_category_key: "flight_hours",
            source_category_name: "Flight Hours",
            source_kind: "carryover",
            employee_wage_rate_id: carryover_rate.id
          }
        ]
      }
    ]

    results = described_class.new(import: import, mappings: mappings, applied_by: create(:user, company: company)).call

    expect(results[:errors]).to be_empty
    expect(pay_period.payroll_items.find_by!(employee: employee).wage_rate_hours).to contain_exactly(
      include("employee_wage_rate_id" => current_rate.id, "regular_hours" => 8.0, "label" => /AIRE current period/),
      include("employee_wage_rate_id" => carryover_rate.id, "regular_hours" => 3.5, "label" => /AIRE carryover from Aug 14, 2026/)
    )
  end

  it "applies hours and preserves a recoverable acknowledgement when enqueueing fails" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "retry@example.com")
    create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    adjustments = [
      {
        "source_time_entry_id" => "101",
        "line_key" => "flight-current",
        "source_kind" => "current",
        "original_work_date" => "2026-08-20",
        "original_week_start" => "2026-08-16",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      }
    ]
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))
    allow(AirePayrollStatusSyncJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

    results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

    expect(results[:errors]).to be_empty
    expect(import.reload.status).to eq("applied")
    acknowledgement = import.aire_payroll_acknowledgements.find_by!(status: "imported")
    expect(acknowledgement).to have_attributes(enqueued_at: nil, delivered_at: nil, last_error: "queue unavailable")
    expect(import.reload.source_processing_sync_error).to eq("queue unavailable")

    allow(AirePayrollStatusSyncJob).to receive(:perform_later).and_return(true)
    AirePayrollAcknowledgement.dispatch_pending!(ids: [ acknowledgement.id ])
    expect(acknowledgement.reload).to have_attributes(last_error: nil)
    expect(acknowledgement.enqueued_at).to be_present
  end

  it "does not allow an included finalized employee row to be skipped" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com", pay_rate: 25)
    create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    adjustment = {
      "source_time_entry_id" => "101",
      "line_key" => "flight:2500",
      "source_kind" => "current",
      "original_work_date" => "2026-08-17",
      "original_week_start" => "2026-08-16",
      "source_category_id" => "flight",
      "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
      "total_hours" => 8.0,
      "regular_hours" => 8.0,
      "overtime_hours" => 0.0
    }
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ]))

    results = described_class.new(
      import: import,
      mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id, include: false } ],
      applied_by: create(:user, company: company)
    ).call

    expect(results[:errors]).to contain_exactly(include(error: "Finalized AIRE batch rows cannot be skipped"))
    expect(import.reload.status).to eq("previewed")
    expect(pay_period.payroll_items).to be_empty
  end

  it "records an empty finalized batch as applied without creating payroll items" do
    company, pay_period, source = setup_records
    payload = payload_for(pay_period: pay_period, employee: nil, adjustments: [], batch_id: "AIRE-PAY-EMPTY-001")
    payload["cutoff_at"] = "2026-08-31T11:00:00+10:00"
    payload["export"]["cutoff_at"] = payload["cutoff_at"]
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    import = preview_import(pay_period: pay_period, source: source, payload: payload)

    results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

    expect(results).to eq(applied: [], skipped: [], errors: [])
    expect(import.reload.status).to eq("applied")
    expect(pay_period.payroll_items).to be_empty
  end

  it "blocks a correction whose resulting regular or overtime bucket is negative" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com", pay_rate: 25)
    create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    adjustment = {
      "source_time_entry_id" => "101",
      "line_key" => "flight:2500",
      "source_kind" => "correction",
      "original_work_date" => "2026-08-17",
      "original_week_start" => "2026-08-16",
      "source_category_id" => "flight",
      "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
      "total_hours" => -2.0,
      "regular_hours" => -2.0,
      "overtime_hours" => 0.0
    }
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ]))

    results = described_class.new(
      import: import,
      mappings: [],
      applied_by: create(:user, company: company),
      acknowledge_negative_adjustments: true,
      negative_adjustment_note: "Reviewed negative correction for correction workflow."
    ).call

    expect(results[:errors]).to contain_exactly(include(error: /payroll correction workflow/i))
    expect(import.reload.status).to eq("previewed")
  end

  it "blocks a correction whose hours net to zero but whose Cornerstone gross adjustment is negative" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com", pay_rate: 25)
    flight_rate = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    admin_rate = create(:employee_wage_rate, employee: employee, label: "Admin Duties", rate: 20, is_primary: false, active: true)
    base = {
      "source_time_entry_id" => "101",
      "source_kind" => "correction",
      "original_work_date" => "2026-08-17",
      "original_week_start" => "2026-08-16",
      "overtime_hours" => 0.0
    }
    adjustments = [
      base.merge(
        "line_key" => "flight",
        "source_category_id" => "flight",
        "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
        "total_hours" => -10.0,
        "regular_hours" => -10.0
      ),
      base.merge(
        "line_key" => "admin",
        "source_category_id" => "admin",
        "category" => { "id" => "admin", "key" => "admin_duties", "name" => "Admin Duties" },
        "total_hours" => 10.0,
        "regular_hours" => 10.0
      )
    ]
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))
    row = import.processed_payload.fetch("rows").first

    expect(row).to include("estimated_gross_delta" => -50.0)
    expect(row.fetch("warnings")).to include(include("code" => "negative_net_pay_delta", "message" => /correction workflow/))

    results = described_class.new(
      import: import,
      mappings: [
        {
          source_user_id: "aire-user-1",
          employee_id: employee.id,
          include: true,
          wage_rate_mappings: [
            {
              source_category_id: "flight",
              source_category_key: "flight_hours",
              source_category_name: "Flight Hours",
              employee_wage_rate_id: flight_rate.id
            },
            {
              source_category_id: "admin",
              source_category_key: "admin_duties",
              source_category_name: "Admin Duties",
              employee_wage_rate_id: admin_rate.id
            }
          ]
        }
      ],
      applied_by: create(:user, company: company),
      acknowledge_negative_adjustments: true,
      negative_adjustment_note: "Reviewed the negative Cornerstone gross correction."
    ).call

    expect(results[:errors]).to contain_exactly(include(error: /negative Cornerstone payroll gross adjustment/))
    expect(pay_period.payroll_items).to be_empty
  end
end
