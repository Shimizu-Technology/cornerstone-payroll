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

    expect { service.apply!(acknowledgement: "yes") }.to raise_error(ArgumentError, /acknowledgement/)
    expect { service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT) }.to change { batch.reload.status }.from("previewed").to("applied")
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

    described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    expect do
      described_class.new(batch: batch, actor: nil).lock!
    end.to raise_error(ArgumentError, /attributed manager or administrator/)
  end

  it "refuses apply if staged totals no longer equal the preview" do
    batch.historical_paychecks.first.update_column(:net_pay, 1)

    expect do
      described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    end.to raise_error(ArgumentError, /net pay no longer matches/)
    expect(batch.reload).to be_previewed
  end

  it "prevents ordinary edits and deletes after lock" do
    service = described_class.new(batch: batch, actor: actor)
    service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
    service.lock!
    paycheck = batch.historical_paychecks.first

    expect(paycheck.update(gross_pay: 1)).to be(false)
    expect(paycheck.errors.full_messages).to include("Historical paycheck snapshots are immutable")
    expect(paycheck.destroy).to be(false)
    expect(paycheck.errors.full_messages).to include("Applied historical paychecks cannot be deleted")
  end

  it "allows a rejected preview to be removed with all staged rows" do
    expect { batch.destroy! }
      .to change(HistoricalImportBatch, :count).by(-1)
      .and change(HistoricalPaycheck, :count).by(-2)
      .and change(HistoricalPayPeriod, :count).by(-2)
      .and change(HistoricalWorker, :count).by(-2)
  end

  it "prevents deleting an applied import batch" do
    described_class.new(batch: batch, actor: actor).apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)

    expect(batch.destroy).to be(false)
    expect(batch.errors.full_messages).to include("Applied historical imports cannot be deleted")
  end
end
