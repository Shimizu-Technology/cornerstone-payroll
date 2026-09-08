# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalImportBatch do
  subject(:batch) { build(:historical_import_batch) }

  it "requires an explicitly registered source system on persisted batches" do
    batch.source_system = nil

    expect(batch).not_to be_valid
    expect(batch.errors[:source_system]).to include("is not supported")
  end

  it "rejects an unregistered source system" do
    batch.source_system = "unreviewed_provider"

    expect(batch).not_to be_valid
    expect(batch.errors[:source_system]).to include("is not supported")
  end
end
