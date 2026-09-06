# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::ClientBootstrapApplyService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
  end

  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }
  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "previews and atomically prepares every QuickBooks worker as a linked live employee" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call

    expect(bootstrap).to be_ready_to_apply
    expect(bootstrap.preview_summary).to include(
      "worker_count" => 3,
      "active_employee_count" => 2,
      "inactive_employee_count" => 1,
      "variable_pay_employee_count" => 1
    )

    expect do
      described_class.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to change(Employee, :count).by(3)
      .and change(EmployeeWageRate, :count).by(3)
      .and change(EmployeePayrollField, :count).by(2)

    expect(bootstrap.reload).to be_applied
    expect(batch.reload).to be_previewed
    expect(batch.historical_workers.where(mapping_status: "exact_match").count).to eq(3)
    expect(batch.historical_paychecks.where(employee_id: nil)).to be_empty

    active = company.employees.find_by!(first_name: "Alice")
    expect(active).to have_attributes(
      status: "active",
      hire_date: nil,
      address_line1: nil,
      configuration_source: "quickbooks_history",
      configuration_review_status: "needs_review",
      roth_retirement_rate: 0.04.to_d,
      employer_roth_match_rate: 0.04.to_d
    )
    expect(active.employee_payroll_fields.joins(:payroll_field_definition).pluck("payroll_field_definitions.name", :amount)).to eq(
      [ [ "Health Insurance", 105.to_d ] ]
    )

    commission = company.employees.find_by!(first_name: "Charlie")
    expect(commission).to have_attributes(employment_type: "salary", salary_type: "variable", pay_rate: 0.to_d)
    expect(commission.employee_payroll_fields.joins(:payroll_field_definition).pluck("payroll_field_definitions.category", :amount)).to eq(
      [ [ "loan", 25.to_d ] ]
    )
  end

  it "is idempotent after a successful apply" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    service = described_class.new(bootstrap: bootstrap, actor: actor, acknowledgement: described_class::ACKNOWLEDGEMENT)

    first = service.call
    expect { service.call }.not_to change(Employee, :count)
    expect(service.call).to eq(first)
  end

  it "rejects a non-empty client and leaves all live records unchanged" do
    create(:employee, company: company, department: create(:department, company: company))
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call

    expect(bootstrap).not_to be_ready_to_apply
    expect(bootstrap.validation_errors).to include(/clean client/)
    expect do
      described_class.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ArgumentError, /clean client/)
    expect(company.employees.count).to eq(1)
    expect(batch.historical_workers.where.not(employee_id: nil)).to be_empty
  end

  it "requires an authorized manager or administrator and the exact acknowledgement" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")

    expect do
      described_class.new(bootstrap: bootstrap, actor: accountant, acknowledgement: described_class::ACKNOWLEDGEMENT).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)
    expect do
      described_class.new(bootstrap: bootstrap, actor: actor, acknowledgement: "yes").call
    end.to raise_error(ArgumentError, /Type PREPARE CLEAN CLIENT EMPLOYEES/)
  end

  it "rejects a deactivated administrator at preview, queue, and apply service boundaries" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    actor.update_columns(active: false)

    expect do
      QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor.reload).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)
    expect do
      QuickbooksHistory::ClientBootstrapEnqueueService.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)
    expect do
      described_class.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)
    expect(company.employees).to be_empty
  end

  it "returns a concurrently applied bootstrap instead of rewriting its preview" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    allow(batch).to receive(:lock!).and_wrap_original do |original|
      bootstrap.update_columns(status: "applied", applied_at: Time.current, applied_by_id: actor.id)
      original.call
    end
    allow(QuickbooksHistory::ClientBootstrapPlan).to receive(:new).and_call_original

    result = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call

    expect(result.reload).to be_applied
    expect(QuickbooksHistory::ClientBootstrapPlan).not_to have_received(:new)
  end

  it "persists a durable dispatch and recovers when the job adapter becomes available" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).and_raise(StandardError, "private adapter failure")

    result = nil
    expect do
      result = QuickbooksHistory::ClientBootstrapEnqueueService.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to change(HistoricalClientBootstrapDispatch, :count).by(1)

    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    expect(result.enqueued).to be(false)
    expect(bootstrap.reload).to be_pending
    expect(dispatch.reload.enqueued_at).to be_nil
    expect(dispatch.last_error).to eq("private adapter failure")
    expect(dispatch.dispatch_attempts).to eq(1)
    expect(dispatch.attempt_token).to eq(bootstrap.apply_started_at.iso8601(6))

    allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).and_call_original
    expect do
      HistoricalClientBootstrapDispatch.dispatch_pending!
    end.to have_enqueued_job(QuickbooksHistory::ClientBootstrapJob).with(
      bootstrap.id, actor.id, bootstrap.apply_started_at.iso8601(6)
    )
    expect(dispatch.reload.enqueued_at).to be_present
    expect(dispatch.last_error).to be_nil
  end

  it "backfills a durable dispatch for an already-pending preparation" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    bootstrap.update!(status: "pending", apply_started_at: Time.current)

    expect do
      result = QuickbooksHistory::ClientBootstrapEnqueueService.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
      expect(result.enqueued).to be(true)
    end.to change(HistoricalClientBootstrapDispatch, :count).by(1)
      .and have_enqueued_job(QuickbooksHistory::ClientBootstrapJob).with(
        bootstrap.id, actor.id, bootstrap.apply_started_at.iso8601(6)
      )
  end

  it "rejects plan drift between preview and apply" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    company.update!(pay_frequency: "weekly")

    expect do
      described_class.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: described_class::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ArgumentError, /preview changed/)
    expect(company.employees).to be_empty
  end

  it "rolls back every employee and link when any setup write fails" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    service = described_class.new(
      bootstrap: bootstrap,
      actor: actor,
      acknowledgement: described_class::ACKNOWLEDGEMENT
    )
    allow(service).to receive(:create_wage_rates!).and_raise(ActiveRecord::RecordInvalid.new(EmployeeWageRate.new))

    expect { service.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(company.employees).to be_empty
    expect(batch.historical_workers.where.not(employee_id: nil)).to be_empty
    expect(batch.historical_paychecks.where.not(employee_id: nil)).to be_empty
    expect(bootstrap.reload).to be_previewed
  end
end
