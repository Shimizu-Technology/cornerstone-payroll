# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ApplyImportService, "finalized AIRE batches" do
  def setup_records(source_type: "aire_services")
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
      name: source_type == "aire_services" ? "AIRE" : "Neutral time",
      source_type: source_type,
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
    if source_type == "custom"
      TimeTracking::ConnectionIdentity.verify_and_pin!(source: source, payload: {
        "source" => "neutral_time", "integration" => { "source_type" => "neutral_time", "protocol" => "shimizu_time_payroll",
          "protocol_version" => "1.0", "source_instance_id" => SecureRandom.uuid,
          "capabilities" => TimeTracking::Connector::AIRE_CAPABILITIES }
      })
    end
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

  def confirm_mapping!(company:, source:, employee:, source_user_uuid: nil)
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: "aire-user-1",
      source_user_uuid: source_user_uuid
    )
  end

  describe "unset payroll wage rates" do
    def wage_safety_preview(company, pay_period, source, employee)
      confirm_mapping!(company: company, source: source, employee: employee)
      adjustments = [
        {
          "source_time_entry_id" => "unset-rate-101", "line_key" => "flight",
          "source_kind" => "current", "original_work_date" => "2026-08-20",
          "original_week_start" => "2026-08-16", "source_category_id" => "flight",
          "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
          "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0
        }
      ]
      preview_import(pay_period: pay_period, source: source,
        payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))
    end

    %w[label override saved_preview].each do |match_path|
      it "rejects an unset #{match_path} rate without saving zero wages or import receipts" do
        company, pay_period, source = setup_records
        employee = create(:employee, company: company, department: create(:department, company: company))
        rate = create(:employee_wage_rate, employee: employee, label: match_path == "override" ? "Unconfigured" : "Flight Hours",
          rate: match_path == "saved_preview" ? 25 : nil, is_primary: true)
        create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25) if match_path == "override"
        import = wage_safety_preview(company, pay_period, source, employee)
        category = import.processed_payload.fetch("rows").first.fetch("categories").first
        if match_path == "saved_preview"
          expect(category.fetch("employee_wage_rate_id")).to eq(rate.id)
          rate.update!(rate: nil)
        end
        mappings = if match_path == "override"
          [ { source_user_id: "aire-user-1", employee_id: employee.id, wage_rate_mappings: [
            { source_category_id: "flight", source_category_key: "flight_hours", source_category_name: "Flight Hours",
              source_kind: "current", employee_wage_rate_id: rate.id }
          ] } ]
        else
          []
        end
        item = create(:payroll_item, company: company, pay_period: pay_period, employee: employee,
          hours_worked: 2, holiday_hours: 8, pto_hours: 4)
        before_attributes = item.attributes

        result = described_class.new(import: import, mappings: mappings, applied_by: create(:user, company: company)).call

        expect(result[:errors]).to contain_exactly(include(error: /Map Flight Hours/))
        if match_path == "label"
          expect(category["employee_wage_rate_id"]).to be_nil
          expect(import.processed_payload.fetch("rows").first.fetch("warnings"))
            .to include(include("code" => "unmapped_wage_rate"))
        end
        expect(import.reload.status).to eq("previewed")
        expect(item.reload.attributes).to eq(before_attributes)
        expect(TimeTrackingEntryAllocation.where(time_tracking_import: import)).to be_empty
        expect(AirePayrollAcknowledgement.where(time_tracking_import: import)).to be_empty
        expect(AirePayrollEntryAcknowledgement.where(time_tracking_import: import)).to be_empty
      end
    end

    [ false, true ].each do |explicit_override|
      it "retains an intentional zero rate as a valid saved wage (explicit override: #{explicit_override})" do
        company, pay_period, source = setup_records
        employee = create(:employee, company: company, department: create(:department, company: company))
        rate = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 0, is_primary: true)
        import = wage_safety_preview(company, pay_period, source, employee)
        expect(import.processed_payload.fetch("rows").first.fetch("categories").first)
          .to include("employee_wage_rate_id" => rate.id, "payroll_rate_cents" => 0)

        mappings = explicit_override ? [ { source_user_id: "aire-user-1", employee_id: employee.id, wage_rate_mappings: [
          { source_category_id: "flight", source_category_key: "flight_hours", source_category_name: "Flight Hours",
            source_kind: "current", employee_wage_rate_id: rate.id }
        ] } ] : []
        result = described_class.new(import: import, mappings: mappings, applied_by: create(:user, company: company)).call

        expect(result[:errors]).to be_empty
        expect(import.reload.status).to eq("applied")
        expect(pay_period.payroll_items.find_by!(employee: employee).wage_rate_hours)
          .to contain_exactly(include("employee_wage_rate_id" => rate.id, "rate" => 0.0, "regular_hours" => 8.0))
        expect(TimeTrackingEntryAllocation.where(time_tracking_import: import).count).to eq(1)
      end
    end

    it "rejects unset rates for hourly contractors" do
      company, pay_period, source = setup_records
      employee = create(:employee, :contractor, company: company, department: create(:department, company: company),
        contractor_pay_type: "hourly")
      create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: nil, is_primary: true)
      import = wage_safety_preview(company, pay_period, source, employee)

      result = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(result[:errors]).to contain_exactly(include(error: /Map Flight Hours/))
      expect(pay_period.payroll_items.reload).to be_empty
      expect(import.reload.status).to eq("previewed")
    end

    it "retains the salary pay basis when an old hourly wage amount is unset" do
      company, pay_period, source = setup_records
      employee = create(:employee, :salary, company: company, department: create(:department, company: company))
      create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: nil, is_primary: true)
      import = wage_safety_preview(company, pay_period, source, employee)

      result = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(result[:errors]).to be_empty
      item = pay_period.payroll_items.find_by!(employee: employee)
      expect(item.employment_type).to eq("salary")
      expect(item.pay_rate).to eq(52_000)
      expect(item.hours_worked).to eq(8)
      expect(item.wage_rate_hours).to be_empty
    end

    it "preserves manual holiday and PTO hours at a configured rate when the primary placeholder is unset" do
      company, pay_period, source = setup_records
      employee = create(:employee, company: company, department: create(:department, company: company))
      create(:employee_wage_rate, employee: employee, label: "Unconfigured", rate: nil, is_primary: true)
      rate = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25)
      item = create(:payroll_item, company: company, pay_period: pay_period, employee: employee,
        hours_worked: 0, holiday_hours: 8, pto_hours: 4)
      import = wage_safety_preview(company, pay_period, source, employee)

      result = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(result[:errors]).to be_empty
      expect(item.reload.wage_rate_hours).to contain_exactly(include("employee_wage_rate_id" => rate.id,
        "rate" => 25.0, "regular_hours" => 8.0, "holiday_hours" => 8.0, "pto_hours" => 4.0))
    end
  end

  it "rejects excluded payroll employees without claiming their finalized entries were imported" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 25, is_primary: true, active: true)
    confirm_mapping!(company: company, source: source, employee: employee)
    pay_period.pay_period_excluded_employees.create!(employee: employee)
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
      }
    ]
    import = preview_import(pay_period: pay_period, source: source, payload: payload_for(pay_period: pay_period, employee: employee, adjustments: adjustments))

    result = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

    expect(result[:errors]).to contain_exactly(include(employee_id: employee.id, error: /excluded from this pay period/))
    expect(result[:skipped]).to be_empty
    expect(import.reload.status).to eq("previewed")
    expect(TimeTrackingEntryAllocation.where(time_tracking_import: import)).to be_empty
    expect(AirePayrollAcknowledgement.where(time_tracking_import: import)).to be_empty
    expect(AirePayrollEntryAcknowledgement.where(time_tracking_import: import)).to be_empty
    expect(pay_period.payroll_items.where(employee: employee)).to be_empty
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
              source_kind: "correction",
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
    confirm_mapping!(company: company, source: source, employee: employee, source_user_uuid: source_user_uuid)
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

  it "accepts a legacy rounding exception exactly at the 0.05-hour boundary" do
    company, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "boundary@example.com")
    adjustment = {
      "source_time_entry_id" => "historic-rounding-boundary",
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
      payload: payload_for(
        pay_period: pay_period,
        employee: employee,
        adjustments: [ adjustment ],
        batch_id: "AIRE-PAY-HISTORICAL-ROUNDING-BOUNDARY"
      )
    )
    item = create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      hours_worked: 7.95,
      overtime_hours: 0.05,
      gross_pay: 200.0,
      net_pay: 180.0
    )
    pay_period.update!(status: "committed", committed_at: Time.current)

    result = TimeTracking::ReconcileCommittedImportService.new(
      import: import,
      mappings: [ { source_user_id: "aire-user-1", employee_id: employee.id } ],
      reconciled_by: create(:user, company: company),
      reconciliation_note: "Owner accepted the documented boundary rounding difference."
    ).call

    expect(result.fetch(:errors)).to be_empty
    expect(result.fetch(:rounding_exceptions)).to contain_exactly(
      include(
        "regular_difference_hours" => "-0.05",
        "overtime_difference_hours" => "+0.05",
        "total_difference_hours" => "+0.00"
      )
    )
    expect(item.reload).to have_attributes(hours_worked: 7.95, overtime_hours: 0.05, gross_pay: 200.0, net_pay: 180.0)
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
        item.check_events.create!(
          event_type: event_type,
          check_number: item.check_number,
          effective_on: state_at.to_date,
          created_at: state_at,
          updated_at: state_at
        )
        item.check_events.create!(
          event_type: "renumbered",
          check_number: "9999",
          effective_on: state_at.to_date,
          created_at: state_at + 1.hour,
          updated_at: state_at + 1.hour
        )
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
        source_event_key: "reconciliation_payment_#{item.id}:#{import.id}:#{payment_status}:#{item.id}:historic-payment:flight-current"
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
    confirm_mapping!(company: company, source: source, employee: employee)
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

    expect(results[:errors]).to contain_exactly(include(error: "Finalized time tracking batch rows cannot be skipped"))
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
    confirm_mapping!(company: company, source: source, employee: employee)
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
    confirm_mapping!(company: company, source: source, employee: employee)
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
  it "previews and applies a neutral producer's exact lines using the same payroll calculation and receipt path" do
    company, pay_period, source = setup_records(source_type: "custom")
    employee = create(:employee, company: company, department: create(:department, company: company), email: "neutral-worker@example.com")
    rate = create(:employee_wage_rate, employee: employee, label: "Work", rate: 25, is_primary: true, active: true)
    uuid = SecureRandom.uuid
    adjustment = { "source_time_entry_id" => "101", "line_key" => "work:2500", "source_kind" => "current",
      "original_work_date" => "2026-08-20", "original_week_start" => "2026-08-16", "source_category_id" => "work",
      "category" => { "id" => "work", "key" => "work", "name" => "Work" },
      "total_hours" => 10.0, "regular_hours" => 8.0, "overtime_hours" => 2.0 }
    payload = payload_for(pay_period: pay_period, employee: employee, adjustments: [ adjustment ], batch_id: "NEUTRAL-101")
    payload["source"] = "neutral_time"
    # The real HTTP client requires the pinned descriptor. This test's client
    # double must retain that same producer contract in the frozen batch.
    payload["integration"] = { "source_type" => "neutral_time", "protocol" => source.source_protocol,
      "protocol_version" => source.source_protocol_version, "source_instance_id" => source.expected_source_instance_id,
      "capabilities" => source.source_capabilities, "policy_constraints" => source.source_policy_constraints }
    payload["employees"].first["source_user_uuid"] = uuid
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    confirm_mapping!(company: company, source: source, employee: employee, source_user_uuid: uuid)
    import = preview_import(pay_period: pay_period, source: source, payload: payload)
    results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call
    expect(results[:errors]).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item.wage_rate_hours).to contain_exactly(include("employee_wage_rate_id" => rate.id,
      "regular_hours" => 8.0, "overtime_hours" => 2.0, "label" => /Neutral time current period/))
    expect(import.reload).to have_attributes(status: "applied", external_batch_id: "NEUTRAL-101")
    expect(import.time_tracking_entry_allocations).to contain_exactly(have_attributes(source_user_uuid: uuid,
      source_time_entry_id: "101", line_key: "work:2500", regular_hours: 8, overtime_hours: 2))
    expect(import.aire_payroll_entry_acknowledgements.pluck(:status, :source_time_entry_id))
      .to contain_exactly([ "imported", "101" ])
  end
  it "fails closed without payroll writes when a preview's required capability is revoked" do
    company, pay_period, source = setup_records(source_type: "custom")
    payload = payload_for(pay_period: pay_period, employee: nil, adjustments: [])
    payload["source"] = "neutral_time"
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    import = preview_import(pay_period: pay_period, source: source, payload: payload)
    source.update!(source_capabilities: [ "time_summary_v1" ])
    expect { described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call }
      .to raise_error(ArgumentError, /does not support finalized batch/)
    expect(import.reload.status).to eq("previewed")
    expect(pay_period.payroll_items).to be_empty
    expect(import.time_tracking_entry_allocations).to be_empty
    expect(import.aire_payroll_acknowledgements).to be_empty
  end

  it "requires history approval for draft preview and apply while keeping committed historical review available" do
    company, pay_period, source = setup_records(source_type: "custom")
    payload = payload_for(pay_period: pay_period, employee: nil, adjustments: [])
    payload["source"] = "neutral_time"
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    import = preview_import(pay_period: pay_period, source: source, payload: payload)
    source.update!(historical_reconciliation_required: true)
    expect { TimeTracking::BatchImportPreviewService.new(pay_period: pay_period, source: source).call }
      .to raise_error(ArgumentError, /historical payroll reconciliation/)
    expect { described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call }
      .to raise_error(ArgumentError, /historical payroll reconciliation/)
    expect(import.reload.status).to eq("previewed")
    expect(pay_period.payroll_items).to be_empty
    expect(import.aire_payroll_acknowledgements).to be_empty
    pay_period.update!(status: "committed", committed_at: Time.current)
    expect(preview_import(pay_period: pay_period, source: source, payload: payload)).to eq(import)
    result = TimeTracking::ReconcileCommittedImportService.new(import: import, mappings: [], reconciled_by: create(:user, company: company),
      reconciliation_note: "Verified empty historical source batch").call
    expect(result[:errors]).to be_empty
    expect(import.reload.status).to eq("applied")
    expect(pay_period.payroll_items).to be_empty
  end

  describe "regular salary roster after a connected import", type: :request do
    def prepare_regular_roster(import_hours: true, **period_attributes)
      company, period, source = setup_records
      period.update!(period_attributes) if period_attributes.any?
      actor = create(:user, company: company, role: "admin")
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)
      create(:tax_table, tax_year: 2026)
      hourly = create(:employee, company: company, email: "hourly-roster@example.com", pay_rate: 25)
      create(:employee_wage_rate, employee: hourly, label: "Flight Hours", rate: 25, is_primary: true)
      salary = create(:employee, :salary, company: company, first_name: "Dana", last_name: "SyntheticSalary", pay_rate: 52_000)
      import = nil
      if import_hours
        confirm_mapping!(company: company, source: source, employee: hourly)
        adjustments = [ {
          "source_time_entry_id" => "salary-roster-hours", "line_key" => "flight:2500",
          "source_kind" => "current", "original_work_date" => "2026-08-20", "original_week_start" => "2026-08-16",
          "source_category_id" => "flight", "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
          "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0
        } ]
        payload = payload_for(pay_period: period, employee: hourly, adjustments: adjustments)
        import = preview_import(pay_period: period, source: source, payload: payload)
        result = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call
        expect(result[:errors]).to be_empty
        expect(period.payroll_items.pluck(:employee_id)).to eq([ hourly.id ])
      end
      [ company, period, hourly, salary, import ]
    end

    def calculate_roster(period, **inputs)
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: inputs, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "errors")).to be_empty
    end

    it "exposes initial salary defaults after real finalized import application and calculates them once" do
      company, period, hourly, salary, import = prepare_regular_roster
      create(:employee, company: company) # An hourly employee absent from the import.
      frozen_payload = import.reload.raw_payload.deep_dup
      frozen_checksum = import.external_batch_checksum
      frozen_allocations = import.time_tracking_entry_allocations.map(&:attributes)

      get "/api/v1/admin/pay_periods/#{period.id}"
      expect(response).to have_http_status(:ok)
      ids = response.parsed_body.dig("pay_period", "default_employee_ids")
      expect(ids).to contain_exactly(hourly.id, salary.id)
      expect(period.payroll_items.count).to eq(1) # Reading defaults must not persist wages.
      calculate_roster(period, employee_ids: ids)
      expect(period.payroll_items.find_by!(employee: salary).gross_pay).to eq(2000.to_d)
      expect(period.payroll_items.find_by!(employee: hourly).gross_pay).to eq(200.to_d)
      calculate_roster(period)
      expect(period.payroll_items.pluck(:employee_id)).to contain_exactly(hourly.id, salary.id)
      expect(period.payroll_items.find_by!(employee: salary).gross_pay).to eq(2000.to_d)
      expect(import.reload.raw_payload).to eq(frozen_payload)
      expect(import.external_batch_checksum).to eq(frozen_checksum)
      expect(import.time_tracking_entry_allocations.map(&:attributes)).to eq(frozen_allocations)
    end

    it "uses the same salary amount in an ordinary manual run" do
      _company, period, _hourly, salary = prepare_regular_roster(import_hours: false)
      calculate_roster(period)
      expect(period.payroll_items.pluck(:employee_id)).to eq([ salary.id ])
      expect(period.payroll_items.first.gross_pay).to eq(2000.to_d)
    end

    it "keeps deliberate exclusions through repeated calculation and import retry" do
      _company, period, hourly, salary, import = prepare_regular_roster
      PayPeriodExcludedEmployee.create!(pay_period: period, employee: salary)
      calculate_roster(period)
      repeated_preview = preview_import(pay_period: period, source: import.time_tracking_source, payload: import.raw_payload)
      expect(repeated_preview).to eq(import)
      expect do
        TimeTracking::ApplyImportService.new(import: repeated_preview, mappings: [], applied_by: import.applied_by).call
      end.to raise_error(ArgumentError, "Only previewed time tracking imports can be applied")
      calculate_roster(period, employee_ids: [ hourly.id, salary.id ])
      expect(period.payroll_items.pluck(:employee_id)).to eq([ hourly.id ])
      expect(response.parsed_body.dig("pay_period", "default_employee_ids")).to eq([ hourly.id ])
    end

    it "preserves explicit selection and does not expand it after calculation invalidation" do
      company, period, hourly, salary = prepare_regular_roster
      calculate_roster(period, employee_ids: [ hourly.id ])
      create(:employee, :salary, company: company)
      period.reload.invalidate_calculation!(reason: "Synthetic setup change")
      expect(period.reload).to have_attributes(status: "draft", calculated_at: nil)
      calculate_roster(period)
      expect(period.payroll_items.pluck(:employee_id)).to eq([ hourly.id ])
      expect(period.payroll_items.where(employee: salary)).not_to exist
    end

    it "does not default salary into a regular run with base salary disabled" do
      _company, period, hourly, salary = prepare_regular_roster(includes_base_salary: false)
      calculate_roster(period)
      expect(period.payroll_items.pluck(:employee_id)).to eq([ hourly.id ])
      expect(period.payroll_items.where(employee: salary)).not_to exist
    end

    it "keeps an adjustment run selected-only even when base salary is enabled" do
      _company, period, hourly, salary = prepare_regular_roster(run_purpose: "adjustment", includes_base_salary: true)
      calculate_roster(period)
      expect(period.payroll_items.pluck(:employee_id)).to eq([ hourly.id ])
      expect(period.payroll_items.where(employee: salary)).not_to exist
    end

    [ true, false ].each do |recurring|
      it "preserves entered salary and recurring setup policy (#{recurring}) on repeat calculation" do
        company, period, hourly, salary = prepare_regular_roster(includes_recurring_items: recurring)
        field = create(:payroll_field_definition, company: company, name: "Synthetic rent", kind: "deduction",
          tax_treatment: "post_tax_deduction", category: "rent", default_amount: 25)
        EmployeePayrollField.create!(employee: salary, payroll_field_definition: field, active: true,
          start_date: period.start_date)
        calculate_roster(period, salary_overrides: { salary.id.to_s => 725 })
        item = period.payroll_items.find_by!(employee: salary)
        expect(item).to have_attributes(salary_override: 725.to_d, gross_pay: 725.to_d)
        expect(item.payroll_item_field_entries.sum(:amount)).to eq(recurring ? 25.to_d : 0.to_d)
        calculate_roster(period)
        expect(item.reload).to have_attributes(salary_override: 725.to_d, gross_pay: 725.to_d)
        expect(item.payroll_item_field_entries.sum(:amount)).to eq(recurring ? 25.to_d : 0.to_d)
        expect(period.payroll_items.pluck(:employee_id)).to contain_exactly(hourly.id, salary.id)
      end
    end
  end
end
