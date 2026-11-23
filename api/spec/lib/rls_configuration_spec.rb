# frozen_string_literal: true

require "rails_helper"

RSpec.describe RlsConfiguration do
  let(:direct) { "postgresql://payroll_app@db.example.test/payroll?sslmode=require" }
  let(:production) { ActiveSupport::EnvironmentInquirer.new("production") }

  it "accepts a direct PostgreSQL URL and rejects poolers and libpq overrides" do
    expect(described_class.direct_url!(direct, "RLS_DATABASE_URL")).to eq(direct)

    [
      "invalid",
      "http://db.example.test/payroll",
      "postgresql:///payroll",
      direct.sub("db.", "db-pooler."),
      direct.sub("db.", "db.pooler."),
      direct.sub(".test/", ".test:6543/"),
      direct.sub(".test/", ".test,other.test/"),
      direct + "&%68ost=other.example.test",
      direct + "&service=elsewhere"
    ].each do |url|
      expect { described_class.direct_url!(url, "RLS_DATABASE_URL") }
        .to raise_error(ArgumentError, "RLS_DATABASE_URL must point to a direct PostgreSQL endpoint")
    end
  end

  it "keeps the default-off boot path away from the runtime role" do
    env = { "RLS_DATABASE_URL" => direct }
    expect(described_class.runtime_url(env)).to be_nil
    expect { |verify| described_class.verify_boot!(environment: production, env: env, &verify) }.not_to yield_control
  end

  it "requires a valid guard mode and a direct URL before verifying the role on production boot" do
    env = { "RLS_CONTEXT_GUARD_MODE" => "invalid" }
    expect { described_class.verify_boot!(environment: production, env: env) }.to raise_error(ArgumentError, /GUARD_MODE/)

    env["RLS_CONTEXT_GUARD_MODE"] = "raise"
    expect { described_class.verify_boot!(environment: production, env: env) }.to raise_error(ArgumentError, /Set RLS_DATABASE_URL/)

    env["RLS_DATABASE_URL"] = direct.sub("db.", "db-pooler.")
    expect { described_class.verify_boot!(environment: production, env: env) }.to raise_error(ArgumentError, /direct PostgreSQL/)

    env["RLS_DATABASE_URL"] = direct
    expect { |verify| described_class.verify_boot!(environment: production, env: env, &verify) }.to yield_control
    expect do
      described_class.verify_boot!(environment: production, env: env) { raise "Role verification failed" }
    end.to raise_error("Role verification failed")
  end

  it "skips SQL parsing for secondary connection pools", :rls do
    db_config = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, primary?: false)
    pool = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool, db_config: db_config)
    adapter = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, pool: pool)
    expect(PgQuery).not_to receive(:summary)
    expect(RlsContextGuard.check!(adapter, "SELECT * FROM pay_periods")).to be_nil
  end
end
