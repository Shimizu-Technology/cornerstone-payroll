# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::MappingService do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let!(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
  end
  let(:worker) { batch.historical_workers.find_by!(source_name: "Worker, Alice") }

  after { cleanup_quickbooks_history_uploads }

  it "requires an attributed manager or administrator with company access" do
    expect do
      described_class.new(worker: worker, employee: employee, actor: nil).call
    end.to raise_error(ArgumentError, /attributed manager or administrator/)
    expect do
      described_class.new(worker: worker, employee: employee, actor: accountant).call
    end.to raise_error(ArgumentError, /attributed manager or administrator/)

    expect(worker.reload.employee_id).to be_nil
  end

  it "maps the worker and its snapshots when an authorized operator performs the action" do
    described_class.new(worker: worker, employee: employee, actor: admin).call

    expect(worker.reload).to have_attributes(
      employee_id: employee.id,
      mapping_status: "manual_match",
      match_method: "manual",
      match_confidence: 1
    )
    expect(worker.historical_paychecks.distinct.pluck(:employee_id)).to eq([ employee.id ])
    expect(employee.destroy).to be(false)
    expect(employee.errors.full_messages).to include("Cannot delete record because dependent historical workers exist")
  end

  it "allows multiple historical source identities to link to one live employee" do
    other_worker = batch.historical_workers.find_by!(normalized_name: "worker bob")

    described_class.new(worker: worker, employee: employee, actor: admin).call
    described_class.new(worker: other_worker, employee: employee, actor: admin).call

    expect(batch.historical_workers.where(employee_id: employee.id).count).to eq(2)
    expect(batch.historical_paychecks.where(employee_id: employee.id).count).to eq(2)
  end

  it "records an explicit archive-only disposition without changing live employees" do
    expect do
      described_class.new(worker: worker, employee: nil, actor: admin, archive_only: true).call
    end.not_to change(Employee, :count)

    expect(worker.reload).to have_attributes(
      employee_id: nil,
      mapping_status: "archive_only",
      match_method: "archive_only",
      match_confidence: nil
    )
  end

  it "rejects conflicting live-employee and archive-only choices" do
    expect do
      described_class.new(worker: worker, employee: employee, actor: admin, archive_only: true).call
    end.to raise_error(ArgumentError, /either a live employee or archive-only/)

    expect(worker.reload).to have_attributes(employee_id: nil, mapping_status: "needs_review")
  end

  it "rejects an employee from another company without changing history" do
    other_company = create(:company, organization: company.organization)
    foreign_employee = create(:employee, company: other_company, department: create(:department, company: other_company))

    expect do
      described_class.new(worker: worker, employee: foreign_employee, actor: admin).call
    end.to raise_error(ArgumentError, /same company/)

    expect(worker.reload).to have_attributes(employee_id: nil, mapping_status: "needs_review")
    expect(worker.historical_paychecks.distinct.pluck(:employee_id)).to eq([ nil ])
  end

  it "rejects mapping changes after a batch has been applied" do
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    expect do
      described_class.new(worker: worker, employee: employee, actor: admin).call
    end.to raise_error(ArgumentError, /only be changed while the batch is a preview/)
    expect(worker.reload.employee_id).to be_nil
  end

  it "never permits a staged worker to move to another import batch" do
    other_batch = HistoricalImportBatch.create!(
      company: company,
      source_label: "Other preview",
      bundle_digest: "other-preview-digest",
      importer_version: "test",
      status: "previewed"
    )

    expect(worker.update(historical_import_batch: other_batch)).to be(false)
    expect(worker.errors.full_messages).to include(
      "Historical import batch cannot be changed after the worker is staged"
    )
    expect(worker.reload.historical_import_batch_id).to eq(batch.id)
  end
end
