# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::AirePayrollCockpits", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:external_id) { SecureRandom.uuid }
  let!(:calendar_period) do
    create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period,
      external_pay_period_id: external_id
    )
  end
  let(:client) { instance_double(TimeTracking::Client) }

  before do
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_user).and_return(admin)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
  end

  context "manual payment allocations" do
    let(:pay_period) { create(:pay_period, :committed, company: company) }

    it "audits the actor, allocation command and payment-link explanation" do
      employee = create(:employee, company: company)
      item = create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee, hours_worked: 4)
      uuid = SecureRandom.uuid
      TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
        employee: employee, source_user_id: "91", source_user_uuid: uuid)
      allow(TimeTracking::Client).to receive(:for_payroll_actor).and_return(client)
      allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [ { "source_user_uuid" => uuid,
        "adjustments" => [ { "source_time_entry_id" => "41", "source_time_entry_version" => 2,
          "original_work_date" => pay_period.start_date.iso8601, "regular_hours" => 4, "overtime_hours" => 0 } ] } ])
      allow(client).to receive(:commit_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 0 })
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/manual_allocations", params: {
        payroll_item_id: item.id, source_time_entry_id: "41", source_time_entry_version: 2, source_user_uuid: uuid,
        regular_hours: "4.00", overtime_hours: "0.00", original_work_date: pay_period.start_date.iso8601,
        note: "This issued historical check covers these exact source hours"
      }
      expect(response).to have_http_status(:created)
      allocation = TimeTrackingManualAllocation.last
      audit = AuditLog.find_by!(action: "aire_payroll_cockpit#manual_allocation_created")
      expect(audit.user_id).to eq(admin.id)
      expect(audit.record_id.to_i).to eq(allocation.id)
      expect(audit.metadata).to include("command_id" => allocation.commit_command_id,
        "reason" => allocation.reconciliation_note)
    end
  end

  def period_payload
    {
      "payroll_period" => {
        "external_pay_period_id" => external_id,
        "status" => "scheduled",
        "lock_version" => 2,
        "cutoff_at" => "2026-10-18T17:00:00+10:00"
      },
      "readiness" => {
        "total_entries" => 1,
        "total_hours" => 8.0,
        "eligible_entries" => 1,
        "eligible_hours" => 8.0,
        "pending_approvals" => 0,
        "denied_entries" => 0,
        "missing_punches" => 0,
        "pending_overtime" => 0,
        "lifecycle_counts" => { "eligible_current_period" => 1 }
      },
      "finalized_batch" => nil,
      "processing_history" => [],
      "entry_processing_history" => [
        {
          "event_id" => "cornerstone-check-5001",
          "status" => "payment_issued",
          "occurred_at" => "2026-10-23T00:01:00+10:00",
          "source_time_entry_id" => "42",
          "total_hours" => "8.0",
          "payment_reference" => "5001"
        }
      ],
      "carryovers" => { "total_entries" => 0, "total_hours" => 0 }
    }
  end

  def employee_payload(employee_uuid: SecureRandom.uuid)
    {
      "employees" => [
        {
          "id" => "91",
          "payroll_integration_id" => employee_uuid,
          "full_name" => "Aire Employee",
          "email" => "employee@example.com",
          "active" => true,
          "time_tracking_enabled" => true
        }
      ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false }
    }
  end

  it "returns live AIRE readiness and decorates employees with Cornerstone mappings" do
    employee = create(:employee, company: company, department: create(:department, company: company))
    employee_uuid = SecureRandom.uuid
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: "91",
      source_user_uuid: employee_uuid
    )
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload(employee_uuid: employee_uuid))

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    cockpit = response.parsed_body.fetch("aire_payroll_cockpit")
    expect(cockpit.dig("readiness", "eligible_hours")).to eq(8.0)
    expect(cockpit.dig("entry_processing_history", 0)).to include(
      "status" => "payment_issued",
      "payment_reference" => "5001"
    )
    expect(cockpit.dig("employees", 0, "cornerstone")).to include(
      "status" => "mapped",
      "employee_id" => employee.id,
      "employee_name" => employee.full_name
    )
    expect(cockpit.dig("command_access", "can_command")).to be(false)
  end

  it "compares manual-entry hours even when the pay period was never published to AIRE" do
    unpublished = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 15)
    )
    employee = create(:employee, company: company, department: create(:department, company: company))
    employee_uuid = SecureRandom.uuid
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: "91",
      source_user_uuid: employee_uuid
    )
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(
      "start_date" => "2026-08-16",
      "end_date" => "2026-08-31",
      "generated_at" => "2026-09-15T09:00:00+10:00",
      "employees" => [
        {
          "source_user_id" => "91",
          "source_user_uuid" => employee_uuid,
          "display_name" => "AIRE Employee",
          "regular_hours" => 27.2,
          "overtime_hours" => 1.0,
          "total_hours" => 28.2,
          "adjustments" => [ { "source_kind" => "carryover", "total_hours" => 6.1 } ]
        }
      ],
      "exclusions" => [
        {
          "source_time_entry_id" => "44",
          "source_user_id" => "91",
          "source_user_uuid" => employee_uuid,
          "display_name" => "AIRE Employee",
          "reason" => "pending_approval",
          "held_total_hours" => 1.5
        }
      ],
      "issues" => {},
      "summary" => { "total_hours" => 28.2 }
    )

    get "/api/v1/admin/pay_periods/#{unpublished.id}/aire_payroll_cockpit/manual_review"

    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:payroll_cockpit_manual_review).with(
      start_date: "2026-08-16",
      end_date: "2026-08-31",
      external_pay_period_id: unpublished.id
    )
    expect(response.parsed_body.dig("employees", 0, "cornerstone")).to include(
      "status" => "mapped",
      "employee_id" => employee.id
    )
    expect(response.parsed_body.dig("exclusions", 0, "cornerstone", "employee_id")).to eq(employee.id)
  end

  it "uses the exact AIRE source that published the pay period" do
    source.update!(active: false)
    create(
      :time_tracking_source,
      company: company,
      source_type: "aire_services",
      name: "Replacement AIRE source",
      base_url: "https://replacement-aire.example.com",
      active: true
    )
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response).to have_http_status(:ok)
    expect(TimeTracking::Client).to have_received(:new).with(source, delegation: nil).at_least(:once)
  end

  it "marks unknown AIRE identities as unmapped" do
    suggestion = create(
      :employee,
      company: company,
      department: create(:department, company: company),
      first_name: "Aire",
      last_name: "Employee",
      email: "employee@example.com"
    )
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    mapping = response.parsed_body.dig("aire_payroll_cockpit", "employees", 0, "cornerstone")
    expect(mapping.fetch("status")).to eq("unmapped")
    expect(mapping.fetch("suggestions")).to contain_exactly(
      include(
        "employee_id" => suggestion.id,
        "employee_name" => suggestion.full_name,
        "basis" => "same_email_and_name"
      )
    )
    expect(response.parsed_body.dig("aire_payroll_cockpit", "payroll_employee_options")).to include(
      include("employee_id" => suggestion.id, "employee_name" => suggestion.full_name)
    )
  end

  it "verifies and saves an explicit AIRE employee link" do
    employee_uuid = SecureRandom.uuid
    target = create(:employee, company: company, department: create(:department, company: company))
    allow(client).to receive(:payroll_cockpit_employee).with(employee_id: "91").and_return(
      "employee" => {
        "id" => "91",
        "payroll_integration_id" => employee_uuid,
        "full_name" => "Aire Employee",
        "email" => "employee@example.com",
        "active" => true,
        "time_tracking_enabled" => true
      }
    )

    expect do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/employee_mapping", params: {
        source_user_id: "91",
        source_user_uuid: employee_uuid,
        employee_id: target.id
      }
    end.to change(TimeTrackingEmployeeMapping, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("employee_mapping")).to include(
      "source_user_id" => "91",
      "source_user_uuid" => employee_uuid,
      "employee_id" => target.id,
      "employee_name" => target.full_name,
      "status" => "mapped"
    )
    expect(AuditLog.order(:id).last).to have_attributes(
      user_id: admin.id,
      company_id: company.id,
      action: "time_tracking_employee_mapping#confirmed",
      record_type: "TimeTrackingEmployeeMapping"
    )
  end

  it "rejects a stale AIRE UUID instead of linking it by name or email" do
    returned_uuid = SecureRandom.uuid
    target = create(:employee, company: company, department: create(:department, company: company))
    allow(client).to receive(:payroll_cockpit_employee).with(employee_id: "91").and_return(
      "employee" => {
        "id" => "91",
        "payroll_integration_id" => returned_uuid,
        "full_name" => "Aire Employee",
        "email" => target.email
      }
    )

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/employee_mapping", params: {
      source_user_id: "91",
      source_user_uuid: SecureRandom.uuid,
      employee_id: target.id
    }

    expect(response).to have_http_status(:conflict)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
  end

  it "maps an incomplete AIRE payload to a bad gateway response" do
    allow(client).to receive(:payroll_cockpit_period).and_return("payroll_period" => period_payload.fetch("payroll_period"))
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body.fetch("error")).to eq("#{source.name} returned an incomplete payroll cockpit payload")
  end

  it "does not require a time mapping when AIRE time tracking is disabled" do
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    payload = employee_payload
    payload.fetch("employees").first["time_tracking_enabled"] = false
    allow(client).to receive(:payroll_cockpit_employees).and_return(payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response.parsed_body.dig("aire_payroll_cockpit", "employees", 0, "cornerstone", "status"))
      .to eq("not_required")
  end

  it "returns literal timecards and exception queues" do
    entry = {
      "id" => "42",
      "version" => 3,
      "work_date" => "2026-10-14",
      "start_time" => "08:00 AM",
      "end_time" => "05:00 PM",
      "hours" => 8.0,
      "break_minutes" => 60,
      "capture" => { "entry_method" => "manual", "ordinary" => false },
      "state" => { "approval_status" => "pending", "payable_now" => false },
      "employee" => { "id" => "91", "payroll_integration_id" => SecureRandom.uuid, "name" => "Aire Employee" }
    }
    allow(client).to receive(:payroll_cockpit_time_entries).and_return(
      "payroll_period" => period_payload.fetch("payroll_period"),
      "time_entries" => [ entry ],
      "pagination" => { "current_page" => 1, "per_page" => 250, "total_count" => 1, "total_pages" => 1, "truncated" => false }
    )
    allow(client).to receive(:payroll_cockpit_exceptions).and_return(
      "payroll_period" => period_payload.fetch("payroll_period"),
      "time_exceptions" => [ entry ],
      "time_exception_pagination" => { "current_page" => 1, "per_page" => 250, "total_count" => 1, "total_pages" => 1, "truncated" => false },
      "leave_exceptions" => [],
      "leave_exception_pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 0, "total_pages" => 1, "truncated" => false },
      "carryovers" => {}
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("time_entries", 0)).to include(
      "id" => "42",
      "start_time" => "08:00 AM",
      "end_time" => "05:00 PM",
      "hours" => 8.0
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/exceptions"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("time_exceptions", 0, "state", "approval_status")).to eq("pending")
  end

  it "returns held-time settlement cases with Cornerstone employee mappings" do
    employee = create(:employee, company: company, department: create(:department, company: company))
    employee_uuid = SecureRandom.uuid
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: "91",
      source_user_uuid: employee_uuid
    )
    settlement_case_id = SecureRandom.uuid
    allow(client).to receive(:payroll_cockpit_settlement_cases).and_return(
      "settlement_cases" => [
        {
          "id" => settlement_case_id,
          "version" => 2,
          "status" => "open",
          "employee" => {
            "payroll_integration_id" => employee_uuid,
            "name" => "Aire Employee",
            "email" => "employee@example.com"
          },
          "time" => { "held_total_hours" => 8.0 },
          "routing" => { "destination_kind" => "unassigned" },
          "events" => []
        }
      ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1 },
      "summary" => { "active_count" => 1, "active_hours" => 8.0 }
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/settlement_cases", params: { status: "open" }

    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:payroll_cockpit_settlement_cases).with(
      external_pay_period_id: external_id,
      page: 1,
      per_page: 250,
      status: "open"
    )
    expect(response.parsed_body.dig("settlement_cases", 0, "employee", "cornerstone")).to include(
      "status" => "mapped",
      "employee_id" => employee.id
    )
  end

  it "uses the current operator's delegation for approvals and records an audit event" do
    delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: admin,
      token: "admin-grant"
    )
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: delegation).and_return(delegated_client)
    allow(delegated_client).to receive(:approve_payroll_time_entry).and_return(
      "time_entry" => { "id" => "42", "version" => 4 },
      "command" => { "replayed" => false }
    )
    command_id = SecureRandom.uuid

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/approval", params: {
      command_id: command_id,
      expected_version: 3,
      decision: "DENY",
      reason: "Employee confirmed this was entered in error"
    }

    expect(response).to have_http_status(:ok)
    expect(delegated_client).to have_received(:approve_payroll_time_entry).with(
      entry_id: "42",
      command_id: command_id,
      expected_version: "3",
      decision: "deny",
      reason: "Employee confirmed this was entered in error"
    )
    expect(AuditLog.order(:id).last).to have_attributes(
      user_id: admin.id,
      company_id: company.id,
      action: "aire_payroll_cockpit#time_denied",
      record_type: "AireTimeEntry"
    )
    expect(AuditLog.order(:id).last.metadata.fetch("reason")).to eq("Employee confirmed this was entered in error")
  end

  it "uses the current operator's linked AIRE account without a delegation token" do
    linked_client = instance_double(TimeTracking::Client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => true })
    allow(TimeTracking::Client).to receive(:new)
      .with(source, delegation: nil, actor: admin)
      .and_return(linked_client)
    allow(linked_client).to receive(:approve_payroll_time_entry).and_return(
      "time_entry" => { "id" => "42", "version" => 4 },
      "command" => { "id" => SecureRandom.uuid, "replayed" => false }
    )

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/approval", params: {
      command_id: SecureRandom.uuid,
      expected_version: 3,
      decision: "approve",
      reason: "Verified by payroll"
    }

    expect(response).to have_http_status(:ok)
    expect(linked_client).to have_received(:approve_payroll_time_entry)
  end

  it "uses the current operator's delegation for overtime decisions and records an audit event" do
    delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: admin,
      token: "admin-grant"
    )
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: delegation).and_return(delegated_client)
    allow(delegated_client).to receive(:approve_payroll_overtime).and_return(
      "time_entry" => { "id" => "42", "version" => 4, "state" => { "overtime_status" => "approved" } },
      "command" => { "replayed" => false }
    )
    command_id = SecureRandom.uuid

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/overtime_approval", params: {
      command_id: command_id,
      expected_version: 3,
      decision: "APPROVE",
      reason: "Verified against the approved schedule"
    }

    expect(response).to have_http_status(:ok)
    expect(delegated_client).to have_received(:approve_payroll_overtime).with(
      entry_id: "42",
      command_id: command_id,
      expected_version: "3",
      decision: "approve",
      reason: "Verified against the approved schedule"
    )
    expect(AuditLog.order(:id).last).to have_attributes(
      user_id: admin.id,
      company_id: company.id,
      action: "aire_payroll_cockpit#overtime_approved",
      record_type: "AireTimeEntry",
      record_id: 42
    )
    expect(AuditLog.order(:id).last.metadata.fetch("reason")).to eq("Verified against the approved schedule")
  end

  it "corrects time through the current delegation and records the command audit" do
    delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: admin,
      token: "admin-grant"
    )
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: delegation).and_return(delegated_client)
    allow(delegated_client).to receive(:correct_payroll_time_entry).and_return(
      "time_entry" => { "id" => "42", "version" => 4, "state" => { "approval_status" => "pending" } },
      "command" => { "replayed" => false }
    )
    command_id = SecureRandom.uuid

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/correction", params: {
      command_id: command_id,
      expected_version: 3,
      reason: "Employee confirmed the missed punch",
      work_date: "2026-10-14",
      start_time: "08:00",
      end_time: "17:00",
      time_category_id: 7,
      description: "Regular shift",
      breaks: [ { start_time: "12:00", end_time: "13:00" } ]
    }

    expect(response).to have_http_status(:ok)
    expect(delegated_client).to have_received(:correct_payroll_time_entry).with(
      entry_id: "42",
      command_id: command_id,
      expected_version: "3",
      reason: "Employee confirmed the missed punch",
      attributes: include(
        "work_date" => "2026-10-14",
        "start_time" => "08:00",
        "end_time" => "17:00",
        "time_category_id" => "7",
        "description" => "Regular shift",
        "breaks" => [ include("start_time" => "12:00", "end_time" => "13:00") ]
      )
    )
    expect(AuditLog.order(:id).last).to have_attributes(
      action: "aire_payroll_cockpit#time_corrected",
      record_type: "AireTimeEntry",
      record_id: 42
    )
    expect(AuditLog.order(:id).last.metadata.fetch("reason")).to eq("Employee confirmed the missed punch")
  end

  it "routes held time to a regular payroll or an explicit not-payable disposition" do
    delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: admin,
      token: "admin-grant"
    )
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: delegation).and_return(delegated_client)
    allow(delegated_client).to receive(:route_payroll_settlement_case).and_return(
      "settlement_case" => { "id" => SecureRandom.uuid, "version" => 3 },
      "command" => { "replayed" => false }
    )
    settlement_case_id = SecureRandom.uuid
    command_id = SecureRandom.uuid
    target_pay_period = create(
      :pay_period,
      company: company,
      start_date: pay_period.end_date + 1.day,
      end_date: pay_period.end_date + 15.days,
      pay_date: pay_period.end_date + 25.days
    )
    target_calendar_period = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: target_pay_period
    )
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: target_calendar_period, delivery_status: "delivered")

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/settlement_cases/#{settlement_case_id}/route", params: {
      command_id: command_id,
      expected_version: 2,
      reason: "Move to the next regular payroll",
      destination_kind: "regular",
      target_external_pay_period_id: target_calendar_period.external_pay_period_id
    }

    expect(response).to have_http_status(:ok)
    expect(delegated_client).to have_received(:route_payroll_settlement_case).with(
      case_id: settlement_case_id,
      command_id: command_id,
      expected_version: "2",
      reason: "Move to the next regular payroll",
      destination_kind: "regular",
      target_external_pay_period_id: target_calendar_period.external_pay_period_id,
      action_due_on: target_pay_period.pay_date
    )
    expect(AuditLog.order(:id).last).to have_attributes(
      action: "aire_payroll_cockpit#settlement_case_routed",
      record_type: "AirePayrollSettlementCase",
      record_id: nil
    )
    expect(AuditLog.order(:id).last.metadata.fetch("external_record_id")).to eq(settlement_case_id)
    expect(AuditLog.order(:id).last.metadata.fetch("reason")).to eq("Move to the next regular payroll")
  end

  it "does not expose a false manual supplemental-payroll action" do
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: admin)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/settlement_cases/#{SecureRandom.uuid}/route", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Try a supplemental payroll",
      destination_kind: "supplemental",
      target_external_pay_period_id: "manual-name"
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("next regular payroll")
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "offers only delivered, unfinished regular AIRE periods as routing destinations" do
    pay_period.update!(start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 15), pay_date: Date.new(2026, 10, 25))
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period, delivery_status: "delivered")

    next_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 10, 16),
      end_date: Date.new(2026, 10, 31),
      pay_date: Date.new(2026, 11, 10)
    )
    next_calendar_period = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: next_period
    )
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: next_calendar_period, delivery_status: "delivered")

    unfinished_publication = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: next_calendar_period, schedule_version: 2, delivery_status: "delivered")
    event_payload = {
      "event_id" => SecureRandom.uuid,
      "event_type" => AirePayrollEvent::EVENT_TYPE,
      "occurred_at" => Time.current.iso8601,
      "payroll_batch" => { "batch_id" => "finalized-next-period", "checksum" => "a" * 64 }
    }
    AirePayrollEvent.create!(
      aire_payroll_calendar_period: next_calendar_period,
      aire_payroll_calendar_publication: unfinished_publication,
      time_tracking_source: source,
      event_id: event_payload.fetch("event_id"),
      event_type: AirePayrollEvent::EVENT_TYPE,
      occurred_at: Time.current,
      payload: event_payload,
      payload_checksum: TimeTracking::CanonicalPayload.checksum(event_payload),
      payroll_batch_id: "finalized-next-period",
      payroll_batch_checksum: "a" * 64,
      verification_status: "verified",
      verified_at: Time.current,
      verified_batch_summary: { "checksum" => "a" * 64 }
    )

    undelivered_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 15),
      pay_date: Date.new(2026, 11, 25)
    )
    undelivered_calendar = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: undelivered_period
    )
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: undelivered_calendar, delivery_status: "pending")

    eligible_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 16),
      end_date: Date.new(2026, 11, 30),
      pay_date: Date.new(2026, 12, 10)
    )
    eligible_calendar = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: eligible_period
    )
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: eligible_calendar, delivery_status: "delivered")

    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response).to have_http_status(:ok)
    options = response.parsed_body.dig("aire_payroll_cockpit", "routing_options")
    expect(options).to contain_exactly(include(
      "external_pay_period_id" => eligible_calendar.external_pay_period_id,
      "pay_period_id" => eligible_period.id,
      "start_date" => "2026-11-16",
      "end_date" => "2026-11-30",
      "pay_date" => "2026-12-10"
    ))
  end

  it "does not let an accountant with a delegation send correction or routing commands" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_user).and_return(accountant)
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: accountant)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/correction", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Attempted correction"
    }
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/settlement_cases/#{SecureRandom.uuid}/route", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Attempted routing",
      destination_kind: "not_payable"
    }
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects an unsupported approval decision without calling AIRE" do
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: admin)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/time_entries/42/approval", params: {
      command_id: SecureRandom.uuid,
      expected_version: 3,
      decision: "skip",
      reason: "Unsupported action"
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Decision must be approve or deny")
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "maps AIRE conflicts to an operator-resolvable conflict response" do
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: admin)
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: kind_of(TimeTrackingDelegation)).and_return(delegated_client)
    allow(delegated_client).to receive(:finalize_payroll_cockpit_period)
      .and_raise(TimeTracking::Client::Error.new("AIRE: period changed", response_status: 409))

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/finalize", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Cutoff review complete"
    }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("AIRE: period changed")
  end

  it "retains the cutoff reason in the local finalization audit" do
    delegation = create(
      :time_tracking_delegation,
      company: company,
      time_tracking_source: source,
      user: admin,
      token: "admin-grant"
    )
    delegated_client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source, delegation: delegation).and_return(delegated_client)
    allow(delegated_client).to receive(:finalize_payroll_cockpit_period).and_return(
      "result" => { "status" => "finalized", "payroll_batch_id" => "AIRE-PAY-42" },
      "command" => { "replayed" => false }
    )

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/finalize", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Cutoff review complete"
    }

    expect(response).to have_http_status(:accepted)
    expect(AuditLog.order(:id).last).to have_attributes(
      action: "aire_payroll_cockpit#finalization_requested",
      record_type: "PayPeriod",
      record_id: pay_period.id
    )
    expect(AuditLog.order(:id).last.metadata.fetch("reason")).to eq("Cutoff review complete")
  end

  it "lets accountants read the cockpit but not send commands" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_user).and_return(accountant)
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"
    expect(response).to have_http_status(:ok)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/finalize", params: {
      command_id: SecureRandom.uuid,
      expected_version: 2,
      reason: "Attempted command"
    }
    expect(response).to have_http_status(:forbidden)
  end

  it "does not expose another company's period and explains an unpublished calendar" do
    other_period = create(:pay_period)

    get "/api/v1/admin/pay_periods/#{other_period.id}/aire_payroll_cockpit"
    expect(response).to have_http_status(:not_found)

    unpublished = create(:pay_period, company: company)
    get "/api/v1/admin/pay_periods/#{unpublished.id}/aire_payroll_cockpit"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Publish this pay period")

    post "/api/v1/admin/pay_periods/#{unpublished.id}/aire_payroll_cockpit/finalize", params: {
      command_id: SecureRandom.uuid,
      expected_version: 0,
      reason: "Cutoff review complete"
    }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Publish this pay period")
  end
  context "reported payment evidence" do
    let(:uuid) { SecureRandom.uuid }
    let(:service) { instance_double(TimeTracking::PaymentEvidenceHolds) }
    let(:reason) { "Owner reported payment, actual check and delivery evidence pending" }
    let(:payload) { { source_time_entry_id: "41", source_user_uuid: uuid,
      command_id: SecureRandom.uuid, expected_version: 2, reason: reason } }
    before do
      allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: admin).and_return(client)
      allow(TimeTracking::PaymentEvidenceHolds).to receive(:new).with(pay_period: pay_period, source: source, client: client).and_return(service)
    end
    it "audits a delegated hold without creating a payroll item" do
      expect(service).to receive(:create!).with(**payload.merge(expected_version: "2")).and_return("payment_attestation" => { "id" => "501" })
      expect { post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations", params: payload }.not_to change(PayrollItem, :count)
      expect(response).to have_http_status(:created)
      expect(AuditLog.find_by!(action: "aire_payroll_cockpit#payment_hold_recorded").metadata)
        .to include("command_id" => payload[:command_id], "reason" => reason)
    end
    it "preserves remote source conflict feedback" do
      allow(service).to receive(:create!).and_raise(TimeTracking::Client::Error.new("Source version changed", response_status: 409))
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations", params: payload
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("Source version changed")
    end
    it "retracts and audits explicit evidence reasons" do
      permitted = payload.except(:source_time_entry_id)
      expect(service).to receive(:retract!).with(attestation_id: "501", **permitted.merge(expected_version: "2"))
        .and_return("payment_attestation" => { "id" => "501", "status" => "retracted" })
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations/501/retract", params: permitted
      expect(response).to have_http_status(:ok)
      expect(AuditLog.find_by!(action: "aire_payroll_cockpit#payment_hold_retracted").user_id).to eq(admin.id)
    end
    it "rejects employee roles before any source access" do
      admin.update!(role: "employee")
      expect(service).not_to receive(:create!)
      expect(TimeTracking::Client).not_to receive(:for_payroll_actor)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations", params: payload
      expect(response).to have_http_status(:forbidden)
    end
    it "rejects an unassigned accountant despite the historical staff capability" do
      home = create(:company, organization: company.organization)
      admin.update!(role: "accountant", company: home)
      expect(TimeTracking::Client).not_to receive(:for_payroll_actor)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations", params: payload
      expect(response).not_to have_http_status(:created)
    end
    it "reads payment holds with a delegated staff identity on a committed period" do
      pay_period.update!(status: "committed", committed_at: Time.current)
      expect(service).to receive(:review).and_return(candidates: [], payment_attestations: [])
      get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_evidence"
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("no-store")
    end
    it "requires active company and organization scope even for an administrator" do
      company.update!(active: false)
      expect(TimeTracking::Client).not_to receive(:for_payroll_actor)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit/payment_attestations", params: payload
      expect(response).not_to have_http_status(:created)
    end
  end

end
