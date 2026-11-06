# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingSource do
  describe "validations" do
    it "assigns a stable external connection UUID" do
      source = create(:time_tracking_source)

      expect(source.connection_uuid).to match(described_class::UUID_PATTERN)
      expect { create(:time_tracking_source, connection_uuid: source.connection_uuid) }
        .to raise_error(ActiveRecord::RecordInvalid, /Connection uuid has already been taken/i)
    end

    it "requires an HTTP or HTTPS base URL with a host" do
      source = described_class.new(
        company: create(:company),
        name: "Bad Source",
        source_type: "custom",
        base_url: "example.com",
        shared_secret: "secret"
      )

      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("must be an HTTP or HTTPS URL with a host and no embedded credentials")
    end

    it "rejects URLs with embedded credentials" do
      source = described_class.new(
        company: create(:company),
        name: "Credentialed Source",
        source_type: "custom",
        base_url: "https://user:pass@example.com",
        shared_secret: "secret"
      )

      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("must be an HTTP or HTTPS URL with a host and no embedded credentials")
    end

    it "rejects query strings and fragments in base URLs" do
      company = create(:company)
      query_source = described_class.new(
        company: company,
        name: "Query Source",
        source_type: "custom",
        base_url: "https://example.com?target=internal",
        shared_secret: "secret"
      )
      fragment_source = query_source.dup
      fragment_source.name = "Fragment Source"
      fragment_source.base_url = "https://example.com#fragment"

      expect(query_source).not_to be_valid
      expect(fragment_source).not_to be_valid
      expect(query_source.errors[:base_url]).to include("must not include a query or fragment")
      expect(fragment_source.errors[:base_url]).to include("must not include a query or fragment")
    end

    it "does not allow source_type to change after creation" do
      source = described_class.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )

      source.source_type = "cornerstone_tax"

      expect(source).not_to be_valid
      expect(source.errors[:source_type]).to include("cannot be changed after creation")
    end

    it "allows only one active source per company" do
      company = create(:company)
      described_class.create!(
        company: company,
        name: "Primary Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )

      duplicate = described_class.new(
        company: company,
        name: "Second Source",
        source_type: "custom",
        base_url: "https://other.example.com",
        shared_secret: "secret"
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:company_id]).to include("can only have one active time tracking source")
    end

    it "allows inactive source history for the same company" do
      company = create(:company)
      described_class.create!(
        company: company,
        name: "Primary Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )

      inactive = described_class.new(
        company: company,
        name: "Old Source",
        source_type: "custom",
        base_url: "https://old.example.com",
        shared_secret: "secret",
        active: false
      )

      expect(inactive).to be_valid
    end

    it "lets production administrators deactivate legacy HTTP sources but not reactivate them" do
      source = described_class.create!(
        company: create(:company),
        name: "Legacy Source",
        source_type: "custom",
        base_url: "http://legacy.example.com",
        shared_secret: "secret"
      )
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect { source.update!(active: false) }.not_to raise_error

      source.active = true
      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("must use HTTPS in production")
    end

    it "stores long shared secrets without truncating encrypted ciphertext" do
      source = described_class.create!(
        company: create(:company),
        name: "Long Secret Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "s" * 512
      )

      expect(source.reload.shared_secret).to eq("s" * 512)
      expect(source.shared_secret_configured?).to be(true)
    end
  end
end

RSpec.describe TimeTrackingSource, "lock rollout" do
  it "validates the activation date as a semimonthly period start" do
    source = build(:time_tracking_source, source_type: "aire_services", cutoff_enforcement_starts_on: "2026-10-17")
    expect(source).not_to be_valid
    expect(source.errors[:cutoff_enforcement_starts_on]).to include("must be a semimonthly period start (1st or 16th)")
    source.cutoff_enforcement_starts_on = nil
    expect(source).not_to be_valid
  end

  it "audits configuration and rejects model or direct SQL boundary drift" do
    source = create(:time_tracking_source, source_type: "aire_services")
    audit = AuditLog.find_by!(action: "time_tracking_source#lock_rollout_configured", record_id: source.id)
    expect(audit.metadata).to include("cutoff_enforcement_starts_on" => "2026-10-16")
    expect(audit.metadata.fetch("reason")).to be_present
    source.cutoff_enforcement_starts_on = "2026-11-01"
    expect(source).not_to be_valid
    expect do
      described_class.transaction(requires_new: true) { source.update_columns(cutoff_enforcement_starts_on: "2026-11-01") }
    end.to raise_error(ActiveRecord::StatementInvalid, /rollout boundary is immutable/)
    expect(source.reload.cutoff_enforcement_starts_on).to eq(Date.new(2026, 10, 16))
  end

  it "enforces a configured valid date even when validations are bypassed" do
    source = build(:time_tracking_source, source_type: "aire_services", cutoff_enforcement_starts_on: nil)
    expect do
      described_class.transaction(requires_new: true) { source.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid, /time_tracking_lock_rollout_period_start/)
  end
end
