# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::BulkArchiveOnlyService do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
  end

  after { cleanup_quickbooks_history_uploads }

  it "marks only unreviewed workers archive-only without changing live employees" do
    worker = batch.historical_workers.find_by!(source_name: "Worker, Alice")
    employee = create(:employee, company: company)
    QuickbooksHistory::MappingService.new(worker: worker, employee: employee, actor: admin).call

    expect do
      expect(described_class.new(batch: batch, actor: admin).call).to eq(2)
    end.not_to change(Employee, :count)

    expect(worker.reload.mapping_status).to eq("manual_match")
    expect(batch.historical_workers.where(mapping_status: "archive_only").count).to eq(2)
    expect(batch.unresolved_worker_count).to eq(0)
  end

  it "refuses bulk review after the batch is applied" do
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    expect { described_class.new(batch: batch, actor: admin).call }
      .to raise_error(ArgumentError, /only be bulk-reviewed while the batch is a preview/)
  end
end
