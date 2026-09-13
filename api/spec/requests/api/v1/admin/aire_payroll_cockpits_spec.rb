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
  end

  def period_payload
    {
      "payroll_period" => {
        "external_pay_period_id" => external_id,
        "status" => "open",
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
    expect(cockpit.dig("employees", 0, "cornerstone")).to include(
      "status" => "mapped",
      "employee_id" => employee.id,
      "employee_name" => employee.full_name
    )
    expect(cockpit.dig("command_access", "can_command")).to be(false)
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
    allow(client).to receive(:payroll_cockpit_period).and_return(period_payload)
    allow(client).to receive(:payroll_cockpit_employees).and_return(employee_payload)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit"

    expect(response.parsed_body.dig("aire_payroll_cockpit", "employees", 0, "cornerstone", "status"))
      .to eq("unmapped")
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
  end
end
