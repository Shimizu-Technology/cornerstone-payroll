# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::SourceFileVerificationService do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  after { cleanup_quickbooks_history_uploads }

  it "re-verifies binary source files when the storage client labels them as UTF-8" do
    batch = QuickbooksHistory::ImportService.new(
      company: company,
      files: quickbooks_history_uploads,
      actor: actor
    ).call.batch
    source_bytes = batch.historical_import_source_files.index_with do |source_file|
      R2StorageService.new.download(source_file.storage_key)
    end
    storage = instance_double(R2StorageService)
    allow(storage).to receive(:download_with_limit) do |key, max_bytes:|
      source_file = batch.historical_import_source_files.find_by!(storage_key: key)
      source_bytes.fetch(source_file).dup.force_encoding(Encoding::UTF_8)
    end

    result = described_class.new(batch: batch, actor: actor, storage: storage).call

    expect(source_bytes.values).to include(satisfy { |bytes| !bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? })
    expect(result.all_verified).to be(true)
    expect(result.files.pluck(:verification_status).uniq).to eq([ "verified" ])
  end
end
