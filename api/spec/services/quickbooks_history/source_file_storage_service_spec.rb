# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::SourceFileStorageService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  after { cleanup_quickbooks_history_uploads }

  it "removes every object owned by the attempt when a later upload fails" do
    parsed = QuickbooksHistory::BundleParser.new(files: quickbooks_history_uploads).call
    uploaded = {}
    deleted = []
    storage = instance_double(R2StorageService)
    allow(storage).to receive(:upload) do |key, io, content_type:|
      raise R2StorageService::UploadError, "simulated failure" if uploaded.any?

      uploaded[key] = io.read
      "r2://test/#{key}"
    end
    allow(storage).to receive(:download_with_limit) { |key, max_bytes:| uploaded[key] }
    allow(storage).to receive(:delete) { |key| deleted << key }

    expect do
      described_class.new(company: company, actor: actor, storage: storage).store!(parsed: parsed)
    end.to raise_error(
      QuickbooksHistory::SourceFileStorageService::StorageError,
      "QuickBooks source files could not be retained and verified. No preview was created."
    )
    expect(deleted.size).to eq(2)
    expect(deleted.first).to eq(uploaded.keys.sole)
  end

  it "verifies binary downloads even when the storage client labels them as UTF-8" do
    parsed = QuickbooksHistory::BundleParser.new(files: quickbooks_history_uploads).call
    uploaded = {}
    storage = instance_double(R2StorageService, delete: true)
    allow(storage).to receive(:upload) do |key, io, content_type:|
      uploaded[key] = io.read
      "r2://test/#{key}"
    end
    allow(storage).to receive(:download_with_limit) do |key, max_bytes:|
      uploaded.fetch(key).dup.force_encoding(Encoding::UTF_8)
    end

    records = described_class.new(company: company, actor: actor, storage: storage).store!(parsed: parsed)

    expect(uploaded.values).to include(satisfy { |bytes| !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? })
    expect(records.size).to eq(parsed.source_files.size)
    expect(records.pluck(:verification_status).uniq).to eq([ "verified" ])
  end

  it "rejects a source file that changes after parsing" do
    parsed = QuickbooksHistory::BundleParser.new(files: quickbooks_history_uploads).call
    File.open(parsed.source_files.first.path, "ab") { |file| file.write("changed") }
    storage = instance_double(R2StorageService, delete: true)

    expect do
      described_class.new(company: company, actor: actor, storage: storage).store!(parsed: parsed)
    end.to raise_error(
      QuickbooksHistory::SourceFileStorageService::StorageError,
      "QuickBooks source file changed while the bundle was being staged"
    )
    expect(storage).not_to have_received(:delete)
  end
end
