# frozen_string_literal: true

require "rails_helper"
require_relative "../support/staging_storage_helpers"

RSpec.describe "shared production credential containment" do
  include StagingStorageHelpers

  let(:prefix) { "staging/2026-10-25/" }
  let(:shared) do
    staging_storage_env.merge(
      "STAGING_SHARES_PRODUCTION_CLERK" => "true", "STAGING_SHARES_PRODUCTION_STORAGE" => "true",
      "STAGING_STORAGE_WRITE_PREFIX" => prefix,
      "PRODUCTION_STORAGE_BUCKET" => "synthetic-staging-bucket",
      "PRODUCTION_STORAGE_ACCOUNT_ID" => "a" * 32,
      "PRODUCTION_STORAGE_ENDPOINT" => "https://#{'a' * 32}.r2.cloudflarestorage.com",
      "PRODUCTION_STORAGE_ACCESS_KEY_SHA256" => Digest::SHA256.hexdigest("synthetic-staging-key")
    )
  end

  around do |example|
    old = ENV.to_h
    ENV.update(shared)
    example.run
  ensure
    ENV.replace(old)
  end

  before do
    allow_any_instance_of(Net::HTTP).to receive(:connect).and_raise("Synthetic storage spec forbids network")
  end

  def s3
    ActiveStorage::Service::StagingS3Service.new(bucket: ENV.fetch("STAGING_STORAGE_BUCKET"), access_key_id: "synthetic-staging-key", secret_access_key: "synthetic-only", region: "auto", endpoint: ENV.fetch("STAGING_STORAGE_ENDPOINT"), force_path_style: true)
  end

  it "accepts explicitly shared independent provider assertions" do
    expect(StagingStoragePolicy.validate!).to eq(true)
  end

  [ nil, "", "false", "TRUE", "true ", "1" ].each do |value|
    it "rejects partial or misspelled shared flags #{value.inspect}" do
      changed = shared.merge("STAGING_SHARES_PRODUCTION_CLERK" => value)
      expect { StagingOutboundPolicy.validate!(env: changed) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /STAGING_SHARES_PRODUCTION/)
    end
  end

  [ nil, "", "staging/", "staging/2026-02-30/", "staging/0000-01-01/", "staging/2026-1-25/", "staging/2026-10-25", "/staging/2026-10-25/", "staging/2026-10-25/../", "staging/2026-10-25/extra/" ].each do |value|
    it "rejects unsafe prefix #{value.inspect}" do
      expect { StagingStoragePolicy.validate!(env: shared.merge("STAGING_STORAGE_WRITE_PREFIX" => value)) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /STAGING_STORAGE_WRITE_PREFIX/)
    end
  end

  it "rejects misspelled sharing setting names and an orphan prefix" do
    expect { StagingOutboundPolicy.validate!(env: shared.merge("STAGING_SHARES_PRODUCTION_STORAG" => "true")) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /STAGING_SHARES_PRODUCTION/)
    orphan = shared.except("STAGING_SHARES_PRODUCTION_CLERK", "STAGING_SHARES_PRODUCTION_STORAGE")
    expect { StagingOutboundPolicy.validate!(env: orphan) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /STAGING_SHARES_PRODUCTION/)
  end

  it "leaves production and local development unaffected by shared flag values" do
    %w[production development test].each do |environment|
      expect(StagingStoragePolicy.validate!(env: { "DEPLOYMENT_ENV" => environment, "STAGING_SHARES_PRODUCTION_STORAGE" => "typo" })).to eq(true)
    end
  end

  it "reads production R2 keys but never puts or deletes them" do
    ENV["R2_USE_REMOTE_IN_TEST"] = "true"
    service = R2StorageService.new
    client = Aws::S3::Client.new(stub_responses: true)
    # Inject a synthetic client while retaining independently checked config.
    allow(service).to receive(:client).and_return(client)
    client.stub_responses(:get_object, body: "production bytes")
    expect(client).not_to receive(:put_object)
    expect(client).not_to receive(:delete_object)
    expect(service.download("production/private.pdf")).to eq("production bytes")
    expect { service.upload("production/private.pdf", "replacement") }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { service.delete("production/private.pdf") }.not_to raise_error
  end

  it "uploads generated R2 keys only inside the prefix" do
    ENV["R2_USE_REMOTE_IN_TEST"] = "true"
    service = R2StorageService.new
    client = Aws::S3::Client.new(stub_responses: true)
    allow(service).to receive(:client).and_return(client)
    key = StagingStoragePolicy.new_key("documents/new.pdf")
    expect(key).to eq("#{prefix}documents/new.pdf")
    expect(client).to receive(:put_object).with(hash_including(key: key))
    service.upload(key, "new bytes")
  end

  it "reads cloned Active Storage keys and blocks overwrites, composition and cleanup before SDK access" do
    service = s3
    client = service.client.client
    allow(client).to receive(:get_object).and_return(double(data: Aws::S3::Types::GetObjectOutput.new(body: StringIO.new(+"cloned bytes"))))
    expect(service.download("production/private.pdf")).to eq("cloned bytes")
    expect(client).not_to receive(:put_object)
    expect(client).not_to receive(:delete_object)
    expect(client).not_to receive(:delete_objects)
    expect(client).not_to receive(:list_objects_v2)
    expect { service.upload("production/private.pdf", StringIO.new("replacement")) }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { service.compose([ "source" ], "production/private.pdf") }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { service.update_metadata("production/private.pdf", content_type: "text/plain") }.to raise_error(StagingOutboundPolicy::Blocked)
    service.delete("production/private.pdf")
    service.delete_prefixed("variants/production/private.pdf/")
    service.delete_prefixed("staging/")
  end

  it "rejects ambiguous keys even if their string starts with the prefix" do
    service = s3
    expect(service.client.client).not_to receive(:put_object)
    [ "#{prefix}../production.pdf", "#{prefix}/production.pdf", "#{prefix}%2e%2e/private.pdf", "#{prefix}a\\b" ].each do |key|
      expect { service.upload(key, StringIO.new("x")) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
  end

  it "attaches and replaces new blobs under the prefix, and purges cloned blobs without provider deletes" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:active_storage_blobs) do |t|
      t.string :key, null: false
      t.string :filename, null: false
      t.string :content_type
      t.text :metadata
      t.string :service_name, null: false
      t.bigint :byte_size, null: false
      t.string :checksum
      t.datetime :created_at, null: false
    end
    connection.create_table(:active_storage_attachments) do |t|
      t.string :name, null: false
      t.references :record, polymorphic: true, null: false
      t.references :blob, null: false
      t.datetime :created_at, null: false
    end
    connection.create_table(:active_storage_variant_records) do |t|
      t.references :blob, null: false
      t.string :variation_digest, null: false
    end
    ActiveStorage::VariantRecord.reset_column_information
    ActiveStorage::Blob.reset_column_information
    ActiveStorage::Attachment.reset_column_information
    service = s3
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("r2").and_return(service)
    client = service.client.client
    allow(client).to receive(:put_object).and_return(double(data: Aws::S3::Types::PutObjectOutput.new))
    allow(client).to receive(:delete_object).and_return(double(data: Aws::S3::Types::DeleteObjectOutput.new))
    # Payroll has no app attachment model; exercise Rails attachment lifecycle on a synthetic user association.
    User.has_one_attached(:shared_mode_fixture) unless User.reflect_on_attachment(:shared_mode_fixture)
    user = create(:user)
    cloned = ActiveStorage::Blob.create!(key: "production/photo.jpg", filename: "photo.jpg", content_type: "image/jpeg", byte_size: 1, checksum: "x", metadata: { identified: true, analyzed: true }, service_name: "r2")
    user.shared_mode_fixture.attach(cloned)
    expect(client).not_to receive(:delete_object).with(hash_including(key: cloned.key))
    expect(client).not_to receive(:delete_objects)
    user.shared_mode_fixture.attach(io: StringIO.new("new"), filename: "new.txt", content_type: "text/plain", service_name: "r2")
    fresh = user.reload.shared_mode_fixture.blob
    expect(fresh.key).to start_with(prefix)
    cloned.delete
    cloned.purge_later
    expect { ActiveStorage::PurgeJob.perform_now(cloned) }.not_to raise_error
    expect(client).to receive(:delete_object).with(hash_including(key: fresh.key)).and_return(double(data: Aws::S3::Types::DeleteObjectOutput.new))
    user.shared_mode_fixture.purge
    expect(user.reload.shared_mode_fixture).not_to be_attached
  end

  it "deletes an allowed sub-prefix through individually checked HTTP destinations" do
    ENV["CLERK_ISSUER"] = "https://synthetic.clerk.accounts.dev"
    service = s3
    http = Net::HTTP.new(URI(ENV.fetch("STAGING_STORAGE_ENDPOINT")).host, 443)
    http.use_ssl = true
    key = "#{prefix}cleanup/file.txt"
    allow(service.bucket).to receive(:objects).with(prefix: "#{prefix}cleanup/").and_return([ double(key: key), double(key: "production/private.pdf") ])
    expect(service.client.client).not_to receive(:delete_objects)
    expect(service.client.client).to receive(:delete_object).once.with(hash_including(key: key)) do |params|
      expect(StagingOutboundPolicy.http_request!(http, Net::HTTP::Delete.new("/#{params.fetch(:bucket)}/#{params.fetch(:key)}"))).to eq(true)
      double(data: Aws::S3::Types::DeleteObjectOutput.new)
    end
    service.delete_prefixed("#{prefix}cleanup/")
  end

  it "blocks direct protected mutations at the final storage HTTP boundary" do
    ENV["CLERK_ISSUER"] = "https://synthetic.clerk.accounts.dev"
    http = Net::HTTP.new(URI(ENV.fetch("STAGING_STORAGE_ENDPOINT")).host, 443)
    http.use_ssl = true
    bucket = ENV.fetch("STAGING_STORAGE_BUCKET")
    [ Net::HTTP::Put.new("/#{bucket}/production.pdf"), Net::HTTP::Delete.new("/#{bucket}/production.pdf"), Net::HTTP::Post.new("/#{bucket}?delete") ].each do |request|
      expect { StagingOutboundPolicy.http_request!(http, request) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
    expect(StagingOutboundPolicy.http_request!(http, Net::HTTP::Put.new("/#{bucket}/#{prefix}new.pdf"))).to eq(true)
    expect(StagingOutboundPolicy.http_request!(http, Net::HTTP::Get.new("/#{bucket}/production.pdf"))).to eq(true)
  end

  it "logs protected cleanup without disclosing object keys" do
    expect(Rails.logger).to receive(:warn).with(/STAGING.*protected storage delete skipped/)
    expect(Rails.logger).not_to receive(:warn).with(/private-person/)
    s3.delete("private-person.pdf")
  end
end
