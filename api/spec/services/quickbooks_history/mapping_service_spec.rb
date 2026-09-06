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

  it "cannot race a locked batch when changing a mapping" do
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).lock!

    expect do
      described_class.new(worker: worker, employee: employee, actor: admin).call
    end.to raise_error(ArgumentError, /Locked historical worker mappings/)
    expect(worker.reload.employee_id).to be_nil
  end
end
