# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalClientBootstrap do
  def historical_batch(company)
    HistoricalImportBatch.create!(
      company: company,
      source_label: "Synthetic QuickBooks history",
      bundle_digest: "a" * 64,
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION
    )
  end

  it "cannot cross a company boundary" do
    batch = historical_batch(create(:company))
    bootstrap = described_class.new(
      company: create(:company),
      historical_import_batch: batch,
      plan_digest: "b" * 64
    )

    expect(bootstrap).not_to be_valid
    expect(bootstrap.errors[:company_id]).to include("must match the historical import batch")
  end

  it "cannot be changed or deleted after apply" do
    company = create(:company)
    bootstrap = described_class.create!(
      company: company,
      historical_import_batch: historical_batch(company),
      plan_digest: "b" * 64,
      status: "applied",
      applied_at: Time.current
    )

    expect(bootstrap.update(plan_digest: "changed")).to be(false)
    expect(bootstrap.errors[:base]).to include("Applied client bootstraps cannot be changed")
    expect(bootstrap.destroy).to be(false)
    expect(bootstrap.errors[:base]).to include("Client bootstrap evidence cannot be deleted")
  end
end
