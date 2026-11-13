# frozen_string_literal: true

require "rails_helper"

RSpec.describe "General test workspaces" do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization, client_limit: 1) }
  let(:source_company) { create(:company, organization: organization, name: "Spike Coffee Roasters") }
  let(:actor) { create(:user, company: source_company, organization: organization, role: "admin") }
  let(:accountant) { create(:user, company: source_company, organization: organization, role: "accountant") }
  let!(:employee) { create(:employee, company: source_company, department: nil, first_name: "Ada", last_name: "Tester") }
  let!(:old_period) { source_period(Date.new(2026, 7, 25), Date.new(2026, 8, 7), Date.new(2026, 8, 14), 900, "100") }
  let!(:first_recent) { source_period(Date.new(2026, 8, 8), Date.new(2026, 8, 21), Date.new(2026, 8, 28), 1_000, "101") }
  let!(:latest_period) { source_period(Date.new(2026, 8, 22), Date.new(2026, 9, 4), Date.new(2026, 9, 11), 1_100, "102") }

  before { ActiveJob::Base.queue_adapter = :test }
  after { clear_enqueued_jobs }

  it "previews a flexible copy without requiring committed recent payrolls" do
    latest_period.update_columns(status: "calculated", committed_at: nil)

    preview = TestWorkspace::Preview.new(
      source_company: source_company,
      copy_mode: "exclude_recent",
      excluded_payrolls: 2
    ).call

    expect(preview).to include(ready: true, blockers: [], copy_mode: "exclude_recent")
    expect(preview.dig(:copy_summary, :payrolls_to_copy)).to eq(1)
    expect(preview.dig(:copy_summary, :recent_payrolls_excluded)).to eq(2)
    expect(preview.dig(:copy_summary, :other_open_payrolls_not_copied)).to eq(0)
    expect(preview.fetch(:recent_payrolls).first.fetch(:status)).to eq("calculated")
  end

  it "creates more than one general workspace and grants only selected staff" do
    2.times do |index|
      expect {
        TestWorkspace::Create.new(
          source_company: source_company,
          actor: actor,
          acknowledgement: TestWorkspace::Create::ACKNOWLEDGEMENT,
          name: "Spike Sandbox #{index + 1}",
          copy_mode: "setup_only",
          expiration_days: 30,
          assignments: index.zero? ? [ { user_id: accountant.id, workspace_access_level: "operator" } ] : []
        ).call
      }.to have_enqueued_job(TestWorkspace::CloneJob)
    end

    workspaces = source_company.test_workspaces.where(test_workspace_purpose: "sandbox").order(:name)
    expect(workspaces.count).to eq(2)
    expect(workspaces.first.company_assignments.sole).to have_attributes(user: accountant, workspace_access_level: "operator")
    expect(workspaces.last.company_assignments).to be_empty
  end

  it "copies employee setup and selected payroll history as locked, check-free evidence" do
    definition = create(:payroll_field_definition, company: source_company, owner_employee: employee, name: "Phone allowance")
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: definition, amount: 25)
    workspace = create_workspace(copy_mode: "exclude_recent", excluded_payrolls: 2)

    TestWorkspace::Cloner.new(company: workspace, actor: actor).call

    workspace.reload
    copied_employee = workspace.employees.sole
    copied_period = workspace.pay_periods.sole
    expect(workspace).to be_test_workspace_ready
    expect(copied_employee.test_workspace_source_employee).to eq(employee)
    expect(copied_employee.employee_payroll_fields.sole.amount).to eq(25.to_d)
    expect(copied_period).to have_attributes(
      test_workspace_source_pay_period_id: old_period.id,
      test_workspace_role: "baseline",
      status: "approved",
      parallel_run: true
    )
    expect(copied_period.payroll_items.sole).to have_attributes(gross_pay: 900.to_d, check_number: nil)
    expect(copied_period.update(notes: "changed")).to be(false)
  end

  it "archives and restores a workspace without deleting its records" do
    workspace = create_workspace(copy_mode: "setup_only")
    TestWorkspace::Cloner.new(company: workspace, actor: actor).call
    employee_count = workspace.reload.employees.count

    TestWorkspace::Lifecycle.new(company: workspace, actor: actor).archive!
    expect(workspace.reload).to have_attributes(active: false)
    expect(workspace.test_workspace_archived_at).to be_present
    expect(TestWorkspaceAccessPolicy.allowed?(user: actor, company: workspace, request_method: "PATCH")).to be(false)

    TestWorkspace::Lifecycle.new(company: workspace, actor: actor).restore!
    expect(workspace.reload).to have_attributes(active: true, test_workspace_archived_at: nil)
    expect(workspace.employees.count).to eq(employee_count)
  end

  it "copies annual retirement evidence history with the latest verified values and source" do
    first = employee.employee_retirement_year_inputs.create!(company: source_company, tax_year: 2026,
      prior_year_wage_status: "verified", prior_year_fica_wages: 160_000,
      prior_year_wage_source: "2025 employer W-2GU Box 3", employer_additions_before_system: 1_000,
      opening_balances_verified: true, source_reference: "Initial provider reconciliation", reason: "Initial review")
    latest = employee.employee_retirement_year_inputs.create!(first.attributes.except("id", "created_at", "updated_at")
      .merge("employer_additions_before_system" => 900, "reason" => "Corrected reconciliation"))
    workspace = create_workspace(copy_mode: "setup_only")

    TestWorkspace::Cloner.new(company: workspace, actor: actor).call

    copied_employee = workspace.employees.sole
    expect(copied_employee.employee_retirement_year_inputs.count).to eq(2)
    copied = copied_employee.retirement_year_input_for(2026)
    expect(copied).to have_attributes(company: workspace, created_by: actor, employer_additions_before_system: 900.to_d,
      prior_year_fica_wages: 160_000.to_d, source_reference: latest.source_reference, reason: latest.reason)
    expect(copied.created_at).to eq(latest.created_at)
    expect(employee.retirement_year_input_for(2026)).to eq(latest)
  end

  it "rolls an archive back when its audit record cannot be written" do
    workspace = create_workspace(copy_mode: "setup_only")
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

    expect {
      TestWorkspace::Lifecycle.new(company: workspace, actor: actor).archive!
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(workspace.reload).to have_attributes(active: true, test_workspace_archived_at: nil)
  end

  it "makes an expired workspace read-only even for an administrator" do
    workspace = create_workspace(copy_mode: "setup_only")
    workspace.update_column(:test_workspace_expires_at, 1.minute.ago)

    expect(workspace).to be_test_workspace_expired
    expect(TestWorkspaceAccessPolicy.allowed?(user: actor, company: workspace, request_method: "GET")).to be(true)
    expect(TestWorkspaceAccessPolicy.allowed?(user: actor, company: workspace, request_method: "PATCH")).to be(false)
  end

  it "extends an expired workspace without deleting its data" do
    workspace = create_workspace(copy_mode: "setup_only")
    workspace.update_column(:test_workspace_expires_at, 1.minute.ago)
    employee_count = workspace.employees.count

    TestWorkspace::Lifecycle.new(company: workspace, actor: actor).restore!

    expect(workspace.reload.test_workspace_expires_at).to be_within(1.minute).of(90.days.from_now)
    expect(workspace.employees.count).to eq(employee_count)
    expect(TestWorkspaceAccessPolicy.allowed?(user: actor, company: workspace, request_method: "PATCH")).to be(true)
  end

  %w[through_pay_period exclude_recent all_committed].each do |mode|
    it "copies promoted histories with test lineage in #{mode} mode" do
      rehearsal = create(:company, organization: organization, payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "migration_rehearsal", migration_source_company: source_company, migration_rehearsal_status: "ready",
        migration_source_batch: create(:historical_import_batch, company: source_company, status: "locked", locked_at: Time.current, importer_version: "quickbooks-online-payroll-v4"))
      rehearsal_period = create(:pay_period, company: rehearsal, start_date: old_period.start_date,
        end_date: old_period.end_date, pay_date: old_period.pay_date)
      old_period.update!(promotion_source_pay_period: rehearsal_period, promotion_payment_disposition: "process_in_cornerstone",
        promoted_payment_prepared_at: Time.current, promoted_payment_prepared_by: actor)
      workspace = create_workspace(copy_mode: mode, cutoff_pay_period_id: old_period.id)
      TestWorkspace::Cloner.new(company: workspace, actor: actor).call
      baseline = workspace.pay_periods.find_by!(test_workspace_source_pay_period_id: old_period.id)
      expect(baseline).to have_attributes(promotion_source_pay_period_id: nil, promotion_payment_disposition: nil,
        promoted_payment_prepared_at: nil, promoted_payment_prepared_by_id: nil, status: "approved", parallel_run: true)
      expected = mode == "all_committed" ? 3 : 1
      expect(workspace.pay_periods.count).to eq(expected)
      expect(old_period.reload.promotion_source_pay_period).to eq(rehearsal_period)
    end
  end

  it "copies exact opening YTD and the latest revision once without duplicating later payroll" do
    batch = create(:historical_import_batch, company: source_company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: source_company, historical_import_batch: batch,
      status: "applied", plan_digest: "opening", applied_at: Time.current, applied_by: actor)
    first = HistoricalYtdBridge.create!(company: source_company, historical_import_batch: batch, historical_client_bootstrap: bootstrap,
      status: "applied", plan_digest: "opening", applied_at: 1.day.ago, applied_by: actor, apply_acknowledgement: "APPLY HISTORICAL YTD",
      preview_summary: { through_period_end: "2026-07-10", through_pay_date: "2026-07-17" })
    latest = HistoricalYtdBridge.create!(first.attributes.except("id", "created_at", "updated_at").merge(
      revision: 2, supersedes_historical_ytd_bridge: first, applied_at: Time.current, plan_digest: "revision2"))
    [ first, latest ].each_with_index do |bridge, n|
      HistoricalEmployeeYtdBalance.create!(company: source_company, employee: employee, historical_ytd_bridge: bridge,
        tax_year: 2026, through_period_end: "2026-07-10", through_pay_date: "2026-07-17", gross_pay: 199_000 + n,
        social_security_taxable_wages: 184_000, medicare_taxable_wages: 199_000 + n, federal_income_tax: 24_000, loans: 250)
    end
    workspace = create_workspace(copy_mode: "exclude_recent", excluded_payrolls: 2)
    TestWorkspace::Cloner.new(company: workspace, actor: actor).call
    copied = workspace.employees.sole
    expect(copied.historical_employee_ytd_balances.count).to eq(1)
    expect(copied.historical_employee_ytd_balances.sole.ytd_aggregate_totals).to eq(latest.historical_employee_ytd_balances.sole.ytd_aggregate_totals)
    expect(copied.ytd_totals_before(year: 2026, pay_date: first_recent.pay_date, pay_period_id: 2**62)).to eq(
      employee.ytd_totals_before(year: 2026, pay_date: first_recent.pay_date, pay_period_id: 0))
    expect(workspace.reload.test_workspace_manifest.fetch("opening_ytd").sole).to include("source_bridge_id" => latest.id, "source_revision" => 2)
    expect(workspace.historical_import_batches.sole.historical_import_source_files).to be_empty
  end

  it "fails closed when the selected cutoff precedes opening YTD" do
    batch = create(:historical_import_batch, company: source_company, status: "locked", locked_at: Time.current)
    bootstrap = HistoricalClientBootstrap.create!(company: source_company, historical_import_batch: batch, plan_digest: "opening")
    HistoricalYtdBridge.create!(company: source_company, historical_import_batch: batch, historical_client_bootstrap: bootstrap,
      status: "applied", plan_digest: "opening", applied_at: Time.current, applied_by: actor, apply_acknowledgement: "APPLY HISTORICAL YTD",
      preview_summary: { through_period_end: "2026-09-18", through_pay_date: "2026-09-25" })
    workspace = create_workspace(copy_mode: "exclude_recent", excluded_payrolls: 2)
    expect { TestWorkspace::Cloner.new(company: workspace, actor: actor).call }.to raise_error(ArgumentError, /cutoff/)
    expect(workspace.reload.migration_rehearsal_status).to eq("failed")
    expect(workspace.employees).to be_empty
  end

  private

  def source_period(start_date, end_date, pay_date, gross, check_number)
    period = create(:pay_period, :committed, company: source_company, start_date: start_date, end_date: end_date, pay_date: pay_date)
    create(:payroll_item, company: source_company, pay_period: period, employee: employee, gross_pay: gross, net_pay: gross - 100, check_number: check_number)
    period
  end

  def create_workspace(copy_mode:, excluded_payrolls: 2, cutoff_pay_period_id: nil)
    preview = TestWorkspace::Preview.new(
      source_company: source_company,
      copy_mode: copy_mode,
      excluded_payrolls: excluded_payrolls,
      cutoff_pay_period_id: cutoff_pay_period_id
    )
    periods = preview.selected_periods
    source_company.test_workspaces.create!(
      source_company.attributes.slice(*TestWorkspace::Create::COMPANY_FIELDS).merge(
        name: "Spike General Test",
        organization: organization,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: source_company,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        test_workspace_expires_at: 90.days.from_now,
        test_workspace_manifest: {
          purpose: "sandbox",
          copy_mode: copy_mode,
          copied_source_pay_period_ids: periods.map(&:id)
        }
      )
    )
  end
end
