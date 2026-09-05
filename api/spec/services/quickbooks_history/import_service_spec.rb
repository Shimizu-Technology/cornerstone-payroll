# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::ImportService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  after { cleanup_quickbooks_history_uploads }

  it "stages immutable history without creating live payroll or YTD records" do
    live_counts = [ PayPeriod.count, PayrollItem.count, EmployeeYtdTotal.count ]
    expect do
      @result = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call
    end.to change(HistoricalPaycheck, :count).by(2)
      .and change(HistoricalPayPeriod, :count).by(2)
      .and change(HistoricalWorker, :count).by(2)
    expect([ PayPeriod.count, PayrollItem.count, EmployeeYtdTotal.count ]).to eq(live_counts)

    batch = @result.batch
    expect(batch).to be_previewed
    expect(batch.historical_paychecks.find_by(source_employee_name: "Worker, Alice")).to have_attributes(
      gross_pay: 1_000.to_d,
      net_pay: 725.to_d,
      federal_income_tax: 100.to_d
    )
    worker = batch.historical_workers.find_by(source_name: "Worker, Alice")
    encrypted_value = HistoricalWorker.connection.select_value("SELECT private_snapshot FROM historical_workers WHERE id = #{worker.id.to_i}")
    expect(encrypted_value).not_to include("000-00-0001")
    expect(worker.private_snapshot_data.dig("Tax info")).to include("000-00-0001")
  end

  it "returns the existing batch when the same bundle is uploaded again" do
    files = quickbooks_history_uploads
    first = described_class.new(company: company, files: files, actor: actor).call
    second = described_class.new(company: company, files: files, actor: actor).call

    expect(second.idempotent).to be(true)
    expect(second.batch).to eq(first.batch)
    expect(HistoricalImportBatch.count).to eq(1)
    expect(HistoricalPaycheck.count).to eq(2)
  end

  it "flags overlapping paychecks from a different bundle" do
    first = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call
    QuickbooksHistory::LifecycleService.new(batch: first.batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    cleanup_quickbooks_history_uploads

    second = described_class.new(company: company, files: quickbooks_history_uploads(suffix: "changed"), actor: actor).call

    expect(second.batch.validation_errors).to include("2 paycheck snapshot(s) already exist in applied QuickBooks history")
    expect(second.batch).to be_previewed
  end
end
