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
end
