# frozen_string_literal: true

require "rails_helper"
require_relative "../support/staging_storage_helpers"

RSpec.describe "staging storage isolation" do
  include StagingStorageHelpers

  let(:safe) { staging_storage_env }

  around do |example|
    old = ENV.to_h
    example.run
  ensure
    ENV.replace(old)
  end

  it "accepts independently approved R2 and AWS storage" do
    expect(StagingOutboundPolicy.validate_storage!(env: safe)).to eq(true)
    expect(StagingOutboundPolicy.validate_storage!(env: staging_storage_env(provider: :aws))).to eq(true)
  end

  %w[https://collector.example.test http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com:444 https://user@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com/path https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com?secret=x https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.r2.cloudflarestorage.com#fragment].each do |endpoint|
    it "rejects unsafe endpoint #{endpoint}" do
      safe["R2_ENDPOINT"] = endpoint
      expect { StagingOutboundPolicy.validate_storage!(env: safe) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /ENDPOINT/)
      expect { StagingOutboundPolicy.http_host!(URI(endpoint).host, 443, true, env: safe) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
  end

  it "rejects a production account even if staging assertions repeat it" do
    safe["STAGING_STORAGE_ACCOUNT_ID"] = safe["PRODUCTION_STORAGE_ACCOUNT_ID"]
    safe["R2_ACCOUNT_ID"] = safe["PRODUCTION_STORAGE_ACCOUNT_ID"]
    safe["STAGING_STORAGE_ENDPOINT"] = safe["PRODUCTION_STORAGE_ENDPOINT"]
    safe["R2_ENDPOINT"] = safe["PRODUCTION_STORAGE_ENDPOINT"]
    expect { StagingOutboundPolicy.validate_storage!(env: safe) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "rejects a staging endpoint pointing at a different R2 account" do
    safe["STAGING_STORAGE_ENDPOINT"] = safe["R2_ENDPOINT"] = "https://#{'c' * 32}.r2.cloudflarestorage.com"
    expect { StagingOutboundPolicy.validate_storage!(env: safe) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /ENDPOINT/)
  end

  it "does not infer approval from a missing independent endpoint assertion" do
    safe.delete("STAGING_STORAGE_ENDPOINT")
    expect { StagingOutboundPolicy.validate_storage!(env: safe) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /STAGING_STORAGE_ENDPOINT/)
  end

  it "checks explicit Active Storage constructor endpoint and credentials before SDK construction" do
    ENV.update(safe)
    options = { bucket: safe.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: safe.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true }
    expect { ActiveStorage::Service::StagingS3Service.new(**options) }.not_to raise_error
    expect { ActiveStorage::Service::StagingS3Service.new(**options.merge(endpoint: "https://collector.example.test")) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /ENDPOINT/)
    expect { ActiveStorage::Service::StagingS3Service.new(**options.merge(bucket: "synthetic-live-bucket")) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /BUCKET/)
    expect { ActiveStorage::Service::StagingS3Service.new(**options.merge(access_key_id: "synthetic-live-key")) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /ACCESS_KEY/)
  end

  it "blocks S3 read and direct upload URLs without invoking a presigner" do
    ENV.update(safe)
    service = ActiveStorage::Service::StagingS3Service.new(bucket: safe.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: safe.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true)
    expect { service.url("private.pdf", expires_in: 60, disposition: :inline, filename: ActiveStorage::Filename.new("private.pdf"), content_type: "application/pdf") }.to raise_error(StagingOutboundPolicy::Blocked, /STAGING/)
    expect { service.url_for_direct_upload("private.pdf", expires_in: 60, content_type: "application/pdf", content_length: 1, checksum: "x") }.to raise_error(StagingOutboundPolicy::Blocked, /STAGING/)
  end

  it "revalidates already-constructed storage before reads and writes" do
    ENV.update(safe)
    service = ActiveStorage::Service::StagingS3Service.new(bucket: safe.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: safe.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true)
    ENV["R2_ENDPOINT"] = "https://collector.example.test"
    expect(service.client.client).not_to receive(:get_object)
    expect(service.client.client).not_to receive(:put_object)
    expect { service.download("private.pdf") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { service.upload("private.pdf", StringIO.new("x"), checksum: nil) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end
  it "blocks direct R2 signing and revalidates every operation on a reused service" do
    ENV.update(safe)
    service = R2StorageService.new
    expect { service.signed_url("private.pdf") }.to raise_error(StagingOutboundPolicy::Blocked, /STAGING/)
    ENV["R2_ENDPOINT"] = "https://collector.example.test"
    expect { service.download("private.pdf") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { service.upload("private.pdf", "x") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { service.delete("private.pdf") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { service.exists?("private.pdf") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { service.list }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "omits timecard URLs even when copied references are raw production URLs" do
    ENV["DEPLOYMENT_ENV"] = "staging"
    expect(R2StorageService).not_to receive(:new)
    expect(TimecardOcr::StorageService.presigned_url("https://production.invalid/person.jpg")).to be_nil
  end

  it "rejects copied AWS account assertions and region overrides" do
    aws = staging_storage_env(provider: :aws)
    expect { StagingOutboundPolicy.validate_storage!(env: aws.merge("AWS_ACCOUNT_ID" => aws.fetch("PRODUCTION_STORAGE_ACCOUNT_ID"))) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /ACCOUNT/)
    expect { StagingOutboundPolicy.validate_storage!(env: aws.merge("AWS_REGION" => "us-west-2")) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /REGION/)
  end

  it "allows server byte reads and writes with the approved SDK configuration" do
    ENV.update(safe)
    service = ActiveStorage::Service::StagingS3Service.new(bucket: safe.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: safe.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true)
    allow(service.client.client).to receive(:get_object).and_return(double(data: Aws::S3::Types::GetObjectOutput.new(body: StringIO.new(+"synthetic bytes"))))
    allow(service.client.client).to receive(:put_object).and_return(double(data: Aws::S3::Types::PutObjectOutput.new))
    expect(service.download("private.pdf")).to eq("synthetic bytes")
    expect { service.upload("private.pdf", StringIO.new(+"synthetic bytes"), checksum: nil) }.not_to raise_error
  end

  it "blocks private and public service URL generation entrypoints" do
    ENV.update(safe)
    service = ActiveStorage::Service::StagingS3Service.new(bucket: safe.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: safe.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true)
    expect { service.send(:public_url, "private.pdf") }.to raise_error(StagingOutboundPolicy::Blocked, /STAGING/)
    expect { service.send(:private_url, "private.pdf", expires_in: 60, filename: ActiveStorage::Filename.new("private.pdf"), disposition: :inline, content_type: "application/pdf") }.to raise_error(StagingOutboundPolicy::Blocked, /STAGING/)
  end
  it "pins AWS construction to the independent endpoint despite an ambient SDK override" do
    ENV.update(staging_storage_env(provider: :aws))
    ENV["AWS_ENDPOINT_URL_S3"] = "https://collector.example.test"
    service = ActiveStorage::Service::StagingS3Service.new(bucket: "synthetic-staging-bucket", access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "us-east-1")
    expect(service.client.client.config.endpoint.to_s).to eq("https://s3.us-east-1.amazonaws.com")
  end
end
