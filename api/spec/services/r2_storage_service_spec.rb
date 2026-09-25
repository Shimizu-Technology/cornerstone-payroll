# frozen_string_literal: true

require "rails_helper"

RSpec.describe R2StorageService do
  let(:service) { described_class.new }

  before do
    FileUtils.rm_rf(described_class::LOCAL_STORAGE_ROOT)
    allow(service).to receive(:configured?).and_return(false)
  end

  after { FileUtils.rm_rf(described_class::LOCAL_STORAGE_ROOT) }

  it "isolates local objects by Rails environment" do
    expect(described_class::LOCAL_STORAGE_ROOT).to eq(Rails.root.join("tmp", "local_r2_storage", "test"))
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

  it "uses the shared persistent volume for explicit staging local storage" do
    root = Pathname(Dir.mktmpdir("staging-r2-storage-"))
    stub_const("R2StorageService::STAGING_STORAGE_ROOT", root)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DEPLOYMENT_ENV").and_return("staging")
    allow(ENV).to receive(:[]).with("R2_STORAGE_BACKEND").and_return("local")
    allow(ENV).to receive(:[]).with("ACTIVE_STORAGE_SERVICE").and_return("local")
    allow(ENV).to receive(:[]).with("R2_ACCOUNT_ID").and_return(nil)
    allow(ENV).to receive(:[]).with("R2_ACCESS_KEY_ID").and_return(nil)
    allow(ENV).to receive(:[]).with("R2_SECRET_ACCESS_KEY").and_return(nil)

    begin
      first = described_class.new
      first.upload("check-print-runs/test.pdf", "%PDF-1.4\n", content_type: "application/pdf")
      expect(root.join("check-print-runs/test.pdf")).to exist
      expect(described_class.new.download("check-print-runs/test.pdf")).to eq("%PDF-1.4\n")
    ensure
      FileUtils.remove_entry(root)
    end
  end

  it "still requires R2 in production even if local storage is requested" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DEPLOYMENT_ENV").and_return("production")
    allow(ENV).to receive(:[]).with("R2_STORAGE_BACKEND").and_return("local")
    allow(ENV).to receive(:[]).with("R2_ACCOUNT_ID").and_return(nil)
    allow(ENV).to receive(:[]).with("R2_ACCESS_KEY_ID").and_return(nil)
    allow(ENV).to receive(:[]).with("R2_SECRET_ACCESS_KEY").and_return(nil)

    expect { described_class.new }.to raise_error(R2StorageService::ConfigurationError, /R2 not configured/)
  end
end
