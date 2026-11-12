# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditedClientDocumentUpload do
  it "keeps a retry intent for every key that fails, whatever the error, and re-raises the original" do
    company = create(:company)
    result = Struct.new(:uploaded_keys).new(%w[key-a key-b key-c])
    allow(ClientDocumentUploadService).to receive(:new).and_return(double(upload!: result))
    storage = instance_double(R2StorageService)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:delete).with("key-a").and_raise(Errno::ECONNRESET)
    allow(storage).to receive(:delete).with("key-b").and_return(nil)
    allow(storage).to receive(:delete).with("key-c").and_raise(R2StorageService::UploadError, "outage")

    expect do
      described_class.call(company_id: company.id, current_user: create(:user, company: company), params: {}) { raise "audit down" }
    end.to raise_error(RuntimeError, "audit down")

    expect(storage).to have_received(:delete).exactly(3).times
    expect(PortalUploadCleanup.pluck(:file_key)).to contain_exactly("key-a", "key-c")
  end
end
