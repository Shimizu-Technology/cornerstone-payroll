# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::LifecycleService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
  end

  after { cleanup_quickbooks_history_uploads }

  it "requires the exact authoritative-snapshot acknowledgement and then locks reconciled history" do
    service = described_class.new(batch: batch, actor: actor)

    expect { service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT) }.to raise_error(ArgumentError, /Review every QuickBooks worker/)
    review_historical_workers_as_archive_only(batch, actor: actor)
    expect { service.apply!(acknowledgement: "yes") }.to raise_error(ArgumentError, /acknowledgement/)
    expect { service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT) }.to change { batch.reload.status }.from("previewed").to("applied")
    expect { service.lock! }.to raise_error(ArgumentError, /Approve the verified QuickBooks cutover review/)
    approve_historical_cutover(batch, actor: actor)
    expect { service.lock! }.to change { batch.reload.status }.from("applied").to("locked")
    expect(batch.locked_by).to eq(actor)
    expect(batch.locked_at).to be_present
  end

  it "requires an attributed manager or administrator for apply and lock" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")

    expect do
      described_class.new(batch: batch, actor: nil).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /attributed manager or administrator/)
    expect do
      described_class.new(batch: batch, actor: accountant).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /attributed manager or administrator/)

    review_historical_workers_as_archive_only(batch, actor: actor)
    described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    expect do
      described_class.new(batch: batch, actor: nil).lock!
    end.to raise_error(ArgumentError, /attributed manager or administrator/)
  end

  it "refuses to lock a preview before it is applied" do
    expect do
      described_class.new(batch: batch, actor: actor).lock!
    end.to raise_error(ArgumentError, /Apply the historical import before locking/)
    expect(batch.reload).to be_previewed
  end

  it "refuses apply if staged totals no longer equal the preview" do
    review_historical_workers_as_archive_only(batch, actor: actor)
    batch.historical_paychecks.first.update_column(:net_pay, 1)

    expect do
      described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /net pay no longer matches/)
    expect(batch.reload).to be_previewed
  end

  it "prevents ordinary edits and deletes after lock" do
    service = described_class.new(batch: batch, actor: actor)
    review_historical_workers_as_archive_only(batch, actor: actor)
    service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    approve_historical_cutover(batch, actor: actor)
    service.lock!
    paycheck = batch.historical_paychecks.first

    expect(paycheck.update(gross_pay: 1)).to be(false)
    expect(paycheck.errors.full_messages).to include("Historical paycheck snapshots are immutable")
    expect(paycheck.destroy).to be(false)
    expect(paycheck.errors.full_messages).to include("Applied historical paychecks cannot be deleted")
  end

  it "retains preview batches and their staged evidence" do
    expect(batch.destroy).to be(false)
    expect(batch.errors.full_messages).to include("Historical imports cannot be deleted; retain the source and review record")
    expect(batch.historical_paychecks.count).to eq(2)
    expect(batch.historical_pay_periods.count).to eq(2)
    expect(batch.historical_workers.count).to eq(3)
  end

  it "prevents deleting an applied import batch" do
    review_historical_workers_as_archive_only(batch, actor: actor)
    described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)

    expect(batch.destroy).to be(false)
    expect(batch.errors.full_messages).to include("Historical imports cannot be deleted; retain the source and review record")
  end

  it "prevents batch metadata changes after lock" do
    review_historical_workers_as_archive_only(batch, actor: actor)
    service = described_class.new(batch: batch, actor: actor)
    service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    approve_historical_cutover(batch, actor: actor)
    service.lock!

    expect(batch.update(source_label: "Changed after lock")).to be(false)
    expect(batch.errors.full_messages).to include("Locked historical imports cannot be changed")
  end

  it "checks large applied-history key sets in bounded database queries" do
    keys = (1..(QuickbooksHistory::ImportService::EXTERNAL_KEY_QUERY_BATCH_SIZE + 1)).map do |index|
      "source-key-#{index}"
    end
    association = instance_double(ActiveRecord::Associations::CollectionProxy, pluck: keys)
    allow(batch).to receive(:historical_paychecks).and_return(association)
    expect(HistoricalPaycheck).to receive(:joins).twice.and_call_original

    expect(described_class.new(batch: batch, actor: actor).send(:ensure_no_applied_duplicates!)).to be_nil
  end
end
