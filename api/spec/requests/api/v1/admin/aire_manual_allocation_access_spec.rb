# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scoped AIRE manual allocation access", type: :request do
  let(:home) { create(:company) }
  let(:company) { create(:company, organization: home.organization) }
  let(:actor) { create(:user, company: home, organization: home.organization, role: "accountant") }
  let!(:assignment) { create(:company_assignment, user: actor, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:item) { create(:payroll_item, :with_check, pay_period: pay_period, employee: employee, hours_worked: 4) }
  let(:uuid) { SecureRandom.uuid }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:path) { "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_cockpit" }
  let(:allocation_params) do
    { payroll_item_id: item.id, source_time_entry_id: "41", source_time_entry_version: 2,
      source_user_uuid: uuid, regular_hours: "4.00", overtime_hours: "0.00",
      original_work_date: pay_period.start_date.iso8601, note: "This committed check covers these exact source hours" }
  end

  before do
    source
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
      employee: employee, source_user_id: "91", source_user_uuid: uuid)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_user) { User.find(actor.id) }
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => true })
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [ { "source_user_uuid" => uuid,
      "adjustments" => [ { "source_time_entry_id" => "41", "source_time_entry_version" => 2,
        "original_work_date" => pay_period.start_date.iso8601, "regular_hours" => 4, "overtime_hours" => 0 } ] } ])
    allow(client).to receive(:commit_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 0 })
  end

  def existing_allocation(period: pay_period, payroll_item: item)
    TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: payroll_item, employee: payroll_item.employee, created_by: actor,
      source_user_uuid: uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: period.start_date, regular_hours: 4, overtime_hours: 0,
      reconciliation_note: "Verified source hours on this committed payroll item")
  end

  it "allows an assigned linked accountant without configuration privileges or marking an undelivered check paid" do
    post "#{path}/manual_allocations", params: allocation_params
    expect(response).to have_http_status(:created)
    expect(TimeTrackingManualAllocation.last).to have_attributes(created_by_id: actor.id, status: "committed", remote_allocation_id: "501")
    expect(TimeTracking::Client).to have_received(:new).with(source, actor: actor).at_least(:once)
    expect(AuditLog.find_by!(action: "aire_payroll_cockpit#manual_allocation_created").user_id).to eq(actor.id)
    expect(item.reload.check_events).to be_empty
    expect(StaffRolePolicy.allowed?(actor, :manage_client_configuration)).to be(false)
    get "#{path}/manual_review"
    expect(response.parsed_body.fetch("command_access")).to include(
      "can_manage_manual_allocations" => true, "can_command" => false, "can_manage_mappings" => false)
  end

  it "allows an exact existing paycheck link for a mapped inactive historical employee" do
    employee.update!(status: "inactive")
    post "#{path}/manual_allocations", params: allocation_params
    expect(response).to have_http_status(:created)
    expect(TimeTrackingManualAllocation.last.employee_id).to eq(employee.id)
  end

  it "keeps source configuration commands unavailable to the assigned accountant" do
    post "#{path}/time_entries/41/approval", params: {
      command_id: SecureRandom.uuid, expected_version: 2, decision: "approve", reason: "Checked source hours"
    }
    expect(response).to have_http_status(:forbidden)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "uses the assigned accountant's own delegation to create and retry with the original command identity" do
    delegation = create(:time_tracking_delegation, company: company, time_tracking_source: source, user: actor)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
    allow(client).to receive(:commit_payroll_manual_allocation).and_raise(
      TimeTracking::Client::Error.new("Temporary source outage", response_status: 503))
    post "#{path}/manual_allocations", params: allocation_params
    expect(response).to have_http_status(:created)
    allocation = TimeTrackingManualAllocation.last
    expect(allocation.status).to eq("pending_commit")
    command_id = allocation.commit_command_id
    allow(client).to receive(:commit_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 0 })
    post "#{path}/manual_allocations/#{allocation.id}/retry"
    expect(response).to have_http_status(:ok)
    expect(allocation.reload).to have_attributes(status: "committed", commit_command_id: command_id, created_by_id: actor.id)
    expect(TimeTracking::Client).to have_received(:new).with(source, delegation: delegation).at_least(:once)
    expect(client).to have_received(:commit_payroll_manual_allocation).with(hash_including(command_id: command_id)).twice
    get "#{path}/manual_review"
    expect(response.parsed_body.dig("command_access", "can_manage_manual_allocations")).to be(true)
  end

  it "does not offer or create a link without an account link or delegation" do
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
    get "#{path}/manual_review"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("command_access", "can_manage_manual_allocations")).to be(false)
    expect { post "#{path}/manual_allocations", params: allocation_params }.not_to change(TimeTrackingManualAllocation, :count)
    expect(response).to have_http_status(:bad_gateway)
    expect(client).not_to have_received(:commit_payroll_manual_allocation)
    expect(AuditLog.where(action: "aire_payroll_cockpit#manual_allocation_created")).to be_empty
  end

  it "surfaces expired or insufficient remote delegation before creating a local link" do
    create(:time_tracking_delegation, company: company, time_tracking_source: source, user: actor)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
    allow(client).to receive(:payroll_cockpit_manual_review).and_raise(
      TimeTracking::Client::Error.new("Payroll delegation expired or lacks settlement access", response_status: 403))
    expect { post "#{path}/manual_allocations", params: allocation_params }.not_to change(TimeTrackingManualAllocation, :count)
    expect(response).to have_http_status(:failed_dependency)
    expect(client).not_to have_received(:commit_payroll_manual_allocation)
    expect(AuditLog.where(action: "aire_payroll_cockpit#manual_allocation_created")).to be_empty
  end

  it "keeps a failed remote retry pending with its error without inventing payment evidence" do
    allocation = existing_allocation
    allow(client).to receive(:commit_payroll_manual_allocation).and_raise(
      TimeTracking::Client::Error.new("Payroll delegation expired", response_status: 403))
    post "#{path}/manual_allocations/#{allocation.id}/retry"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("manual_allocation")).to include("status" => "pending_commit", "last_sync_error" => "Payroll delegation expired")
    expect(item.reload.check_events).to be_empty
  end

  it "scopes retries to the selected pay period before contacting AIRE" do
    other_period = create(:pay_period, :committed, company: company)
    other_item = create(:payroll_item, :with_check, pay_period: other_period, employee: employee, hours_worked: 4)
    allocation = existing_allocation(period: other_period, payroll_item: other_item)
    before_state = allocation.attributes
    post "#{path}/manual_allocations/#{allocation.id}/retry"
    expect(response).to have_http_status(:not_found)
    expect(allocation.reload.attributes).to eq(before_state)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "rejects a pending old-source allocation after an active replacement is selected, without any side effects" do
    allocation = existing_allocation
    source.update!(active: false)
    create(:time_tracking_source, company: company, source_type: "aire_services")
    allocation_state = allocation.reload.attributes
    item_state = item.reload.attributes
    audit_count = AuditLog.count
    post "#{path}/manual_allocations/#{allocation.id}/retry"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("inactive or different AIRE source")
    expect(allocation.reload.attributes).to eq(allocation_state)
    expect(item.reload.attributes).to eq(item_state)
    expect(AuditLog.count).to eq(audit_count)
    expect(TimeTracking::Client).not_to have_received(:new)
  end

  it "rejects a calendar-selected inactive source and exposes no manual write access" do
    allocation = existing_allocation
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period)
    source.update!(active: false)
    create(:time_tracking_source, company: company, source_type: "aire_services")
    state = allocation.reload.attributes
    audit_count = AuditLog.count
    post "#{path}/manual_allocations/#{allocation.id}/retry"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(allocation.reload.attributes).to eq(state)
    expect(AuditLog.count).to eq(audit_count)
    expect(TimeTracking::Client).not_to have_received(:new)
    get "#{path}/manual_review"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("command_access", "can_manage_manual_allocations")).to be(false)
  end

  {
    "unassigned accountant" => -> { assignment.destroy! },
    "expired company assignment" => -> { assignment.update!(expires_at: 1.minute.ago) },
    "inactive operator" => -> { actor.update!(active: false) },
    "inactive company" => -> { company.update!(active: false) },
    "archived workspace" => -> { company.update_columns(test_workspace_archived_at: Time.current) },
    "inactive organization" => -> { company.organization.update!(status: "inactive") },
    "client user" => -> { actor.update!(role: "client") },
    "wrong tenant" => -> { actor.update_columns(organization_id: create(:organization).id) }
  }.each do |label, setup|
    it "denies #{label} create and retry without local or remote side effects" do
      allocation = existing_allocation
      instance_exec(&setup)
      allocation_state = allocation.attributes
      item_state = item.reload.attributes
      count = TimeTrackingManualAllocation.count
      audit_count = AuditLog.count
      post "#{path}/manual_allocations", params: allocation_params
      expect(response).to have_http_status(:forbidden)
      post "#{path}/manual_allocations/#{allocation.id}/retry"
      expect(response).to have_http_status(:forbidden)
      expect(TimeTrackingManualAllocation.count).to eq(count)
      expect(AuditLog.count).to eq(audit_count)
      expect(allocation.reload.attributes).to eq(allocation_state)
      expect(item.reload.attributes).to eq(item_state)
      expect(TimeTracking::Client).not_to have_received(:new)
    end
  end

  context "read-only workspace reviewer" do
    let(:company) do
      create(:company, organization: home.organization, payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "training_replay", migration_source_company: home, migration_rehearsal_status: "ready")
    end
    let(:pay_period) { create(:pay_period, company: company) }
    let!(:assignment) { create(:company_assignment, user: actor, company: company, workspace_access_level: "reviewer") }

    it "permits reading but disables manual commands and rejects writes" do
      get "#{path}/manual_review"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("command_access", "can_manage_manual_allocations")).to be(false)
      expect { post "#{path}/manual_allocations", params: allocation_params }.not_to change(TimeTrackingManualAllocation, :count)
      expect(response).to have_http_status(:forbidden)
      allocation = existing_allocation
      state = allocation.attributes
      post "#{path}/manual_allocations/#{allocation.id}/retry"
      expect(response).to have_http_status(:forbidden)
      expect(allocation.reload.attributes).to eq(state)
      expect(client).not_to have_received(:commit_payroll_manual_allocation)
    end
  end
end
