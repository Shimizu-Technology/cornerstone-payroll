# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingFileDigest do
  let(:bytes) { "1A2026...123456789...synthetic filing record\r\n" }

  it "is an HMAC-SHA256 under a server key, never the plain SHA-256" do
    digest = described_class.call(bytes)
    expect(digest).to match(/\A[0-9a-f]{64}\z/)
    expect(digest).to eq(described_class.call(bytes.dup))
    expect(digest).not_to eq(Digest::SHA256.hexdigest(bytes))
    expect(digest).to eq(OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key(FilingFileDigest::SALT, 32), bytes))
  end

  it "changes with the key, and its key is not the fingerprint TIN key" do
    other_key = ActiveSupport::KeyGenerator.new("another secret_key_base").generate_key(FilingFileDigest::SALT, 32)
    expect(described_class.call(bytes, key: other_key)).not_to eq(described_class.call(bytes))
    expect(described_class.key).not_to eq(TaxIdDigest.key)
  end

  it "changes when one SSN digit in the file changes" do
    expect(described_class.call(bytes.sub("123456789", "123456788"))).not_to eq(described_class.call(bytes))
  end

  it "writes audit metadata with a named algorithm and no raw hash" do
    expect(described_class.audit_metadata(bytes)).to eq(file_digest: described_class.call(bytes), digest_alg: "hmac-sha256-v1")
  end

  it "matches a file against an audit row, its metadata, or a bare digest" do
    log = AuditLog.new(metadata: described_class.audit_metadata(bytes).stringify_keys)
    expect(described_class.matches?(bytes, log)).to be(true)
    expect(described_class.matches?(bytes, log.metadata)).to be(true)
    expect(described_class.matches?(bytes, described_class.call(bytes))).to be(true)
    expect(described_class.matches?("#{bytes}x", log)).to be(false)
    expect(described_class.matches?(bytes, { "file_digest" => described_class.call(bytes), "digest_alg" => "sha256" })).to be(false)
    expect(described_class.matches?(bytes, { "sha256" => Digest::SHA256.hexdigest(bytes) })).to be(false)
    expect(described_class.matches?(bytes, Digest::SHA256.hexdigest(bytes))).to be(false)
    expect(described_class.matches?(bytes, nil)).to be(false)
  end

  it "drops a raw sha256 only from year-end filing download metadata" do
    metadata = { "year" => 2026, "sha256" => "a" * 64, "file_digest" => "b" * 64 }
    described_class::AUDIT_ACTIONS.each do |action|
      expect(described_class.redact_audit_metadata(action, metadata)).to eq("year" => 2026, "file_digest" => "b" * 64)
    end
    expect(described_class.redact_audit_metadata("check_print_runs#create", metadata)).to eq(metadata)
    expect(described_class.redact_audit_metadata("historical_imports#download_source_file", metadata)).to eq(metadata)
    expect(described_class.redact_audit_metadata("efw2#download", nil)).to be_nil
  end
end
