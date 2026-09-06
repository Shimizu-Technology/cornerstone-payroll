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
