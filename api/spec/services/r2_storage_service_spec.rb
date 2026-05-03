# frozen_string_literal: true

require "rails_helper"

RSpec.describe R2StorageService do
  let(:service) { described_class.new }

  before do
    FileUtils.rm_rf(Rails.root.join("tmp/local_r2_storage"))
    allow(service).to receive(:configured?).and_return(false)
  end

  it "rejects traversal keys for local uploads" do
    expect do
      service.upload("../escape.txt", "hello", content_type: "text/plain")
    end.to raise_error(R2StorageService::UploadError, "Invalid storage key")
  end

  it "rejects traversal keys for local downloads" do
    expect do
      service.download("../escape.txt")
    end.to raise_error(R2StorageService::DownloadError, "Invalid storage key")
  end

  it "rejects local downloads that exceed the requested byte limit" do
    service.upload("invoice-assistant/test.txt", "large payload", content_type: "text/plain")

    expect do
      service.download_with_limit("invoice-assistant/test.txt", max_bytes: 4)
    end.to raise_error(R2StorageService::DownloadError, /exceeds 4 byte download limit/)
  end
end
