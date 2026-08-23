# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveRecordEncryptionConfiguration do
  let(:production) { ActiveSupport::EnvironmentInquirer.new("production") }
  let(:development) { ActiveSupport::EnvironmentInquirer.new("development") }
  let(:empty_credentials) { ActiveSupport::InheritableOptions.new }

  def credentials_with(**values)
    credentials = ActiveSupport::InheritableOptions.new
    credentials[:active_record_encryption] = ActiveSupport::InheritableOptions.new(values)
    credentials
  end

  it "binds production environment values to the effective Rails config" do
    config = ActiveSupport::OrderedOptions.new
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "env-primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "env-deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "env-salt"
    }

    described_class.apply!(
      config: config,
      environment: production,
      env: env,
      credentials: empty_credentials
    )

    expect(config.primary_key).to eq("env-primary")
    expect(config.deterministic_key).to eq("env-deterministic")
    expect(config.key_derivation_salt).to eq("env-salt")
    expect(described_class.configured?(config)).to be(true)
  end

  it "uses encrypted Rails credentials when production environment values are absent" do
    values = described_class.resolve(
      environment: production,
      env: {},
      credentials: credentials_with(
        primary_key: "credential-primary",
        deterministic_key: "credential-deterministic",
        key_derivation_salt: "credential-salt"
      )
    )

    expect(values).to eq(
      primary_key: "credential-primary",
      deterministic_key: "credential-deterministic",
      key_derivation_salt: "credential-salt"
    )
  end

  it "keeps the complete Rails credential key set authoritative in production" do
    values = described_class.resolve(
      environment: production,
      env: {
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "rotated-primary",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "rotated-deterministic",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "rotated-salt"
      },
      credentials: credentials_with(
        primary_key: "credential-primary",
        deterministic_key: "credential-deterministic",
        key_derivation_salt: "credential-salt"
      )
    )

    expect(values).to eq(
      primary_key: "credential-primary",
      deterministic_key: "credential-deterministic",
      key_derivation_salt: "credential-salt"
    )
  end

  it "reports conflicting complete production key sources without exposing either source" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "rotated-primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "rotated-deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "rotated-salt"
    }
    credentials = credentials_with(
      primary_key: "credential-primary",
      deterministic_key: "credential-deterministic",
      key_derivation_salt: "credential-salt"
    )

    expect(described_class.sources_conflict?(environment: production, env: env, credentials: credentials)).to be(true)
  end

  it "reports an incomplete duplicate production key source as a conflict" do
    env = { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "environment-primary" }
    credentials = credentials_with(
      primary_key: "credential-primary",
      deterministic_key: "credential-deterministic",
      key_derivation_salt: "credential-salt"
    )

    expect(described_class.sources_conflict?(environment: production, env: env, credentials: credentials)).to be(true)
  end

  it "accepts identical complete production key sources" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "same-primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "same-deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "same-salt"
    }
    credentials = credentials_with(
      primary_key: "same-primary",
      deterministic_key: "same-deterministic",
      key_derivation_salt: "same-salt"
    )

    expect(described_class.sources_conflict?(environment: production, env: env, credentials: credentials)).to be(false)
  end

  it "fails production configuration before boot when any effective key is missing" do
    expect {
      described_class.resolve(
        environment: production,
        env: { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary" },
        credentials: empty_credentials
      )
    }.to raise_error(
      ActiveRecordEncryptionConfiguration::MissingConfiguration,
      /Missing complete Active Record encryption configuration/
    )
  end

  it "keeps explicit non-production fallback keys for local and test data" do
    values = described_class.resolve(
      environment: development,
      env: {},
      credentials: empty_credentials
    )

    expect(values).to eq(described_class::DEVELOPMENT_DEFAULTS)
  end

  it "does not reuse production Rails credentials for non-production data" do
    values = described_class.resolve(
      environment: development,
      env: {},
      credentials: credentials_with(
        primary_key: "credential-primary",
        deterministic_key: "credential-deterministic",
        key_derivation_salt: "credential-salt"
      )
    )

    expect(values).to eq(described_class::DEVELOPMENT_DEFAULTS)
  end
end
