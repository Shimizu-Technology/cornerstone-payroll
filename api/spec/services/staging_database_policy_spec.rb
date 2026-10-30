# frozen_string_literal: true

require "rails_helper"

RSpec.describe "staging database routing" do
  it "configures encryption before the staging guard first loads Active Record" do
    files = Rails.root.join("config/initializers").children.sort
    encryption = files.index { |path| path.basename.to_s.end_with?("active_record_encryption.rb") }
    containment = files.index { |path| path.basename.to_s == "00_staging_containment.rb" }
    expect(encryption).to be < containment
  end

  let(:env) { { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled", "DATABASE_URL" => "postgresql://staging-db.example.test/synthetic?sslmode=require", "STAGING_DATABASE_HOSTS" => "staging-db.example.test", "PRODUCTION_DATABASE_HOSTS" => "production-db.example.test,192.0.2.10" } }

  %w[hostaddr host port service servicefile options dbname load_balance_hosts target_session_attrs].each do |key|
    it "rejects URL routing override #{key} before a connection opens" do
      env["DATABASE_URL"] += "&#{key}=private-routing-value"
      expect { StagingOutboundPolicy.validate_database!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError) { |error| expect(error.message).not_to include("private-routing-value") }
    end
  end

  %w[PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGSERVICEFILE PGSYSCONFDIR PGOPTIONS PGTARGETSESSIONATTRS PGLOADBALANCEHOSTS].each do |key|
    it "rejects inherited routing override #{key}" do
      env[key] = "private-routing-value"
      expect { StagingOutboundPolicy.validate_database!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /routing/)
    end
  end

  it "accepts only the exact bounded predeploy timeout options" do
    options = "-c lock_timeout=10s -c statement_timeout=15min -c idle_in_transaction_session_timeout=5min"
    expect(StagingDatabasePolicy.validate_config!(env: env.merge("PGOPTIONS" => options))).to eq(true)
    expect(StagingDatabasePolicy.validate_parameters!({ host: "staging-db.example.test", dbname: "synthetic", options: options }, env: env.merge("PGOPTIONS" => options))).to eq(true)
    [ "#{options} -c search_path=public", "#{options} -c role=postgres", "#{options} hostaddr=192.0.2.10", "-c statement_timeout=0", " #{options}" ].each do |unsafe|
      expect { StagingDatabasePolicy.validate_config!(env: env.merge("PGOPTIONS" => unsafe)) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
      expect { StagingDatabasePolicy.validate_parameters!({ host: "staging-db.example.test", dbname: "synthetic", options: unsafe }, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    end
  end

  it "keeps supported TLS options while rejecting multi-host and socket routes" do
    expect(StagingOutboundPolicy.validate_database!(env: env)).to eq(true)
    [ "postgresql://staging-db.example.test,production-db.example.test/synthetic", "postgresql:///synthetic?host=%2Ftmp" ].each do |url|
      expect { StagingOutboundPolicy.validate_database!(env: env.merge("DATABASE_URL" => url)) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    end
  end

  it "checks resolved parameters and effective peer/backend information" do
    policy = StagingDatabasePolicy
    expect { policy.validate_parameters!({ host: "staging-db.example.test", dbname: "synthetic", hostaddr: "192.0.2.10" }, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    raw = double(host: "staging-db.example.test", hostaddr: "192.0.2.10", port: "5432", db: "synthetic")
    expect(raw).not_to receive(:exec)
    expect { policy.validate_live!(raw, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "rejects a real libpq override peer before any backend query" do
    existing = ActiveRecord::Base.connection.raw_connection
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    raw = PG.connect(host: "staging-db.example.test", hostaddr: existing.hostaddr, port: existing.port, dbname: existing.db, user: existing.user, password: config[:password])
    check_env = env.merge("DATABASE_URL" => "postgresql://staging-db.example.test/#{existing.db}", "PRODUCTION_DATABASE_HOSTS" => existing.hostaddr)
    expect { StagingDatabasePolicy.validate_live!(raw, env: check_env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /peer is denied/)
  ensure
    raw&.close
  end

  it "checks backend addresses and resolved role identity as well as peer host" do
    raw = double(host: "staging-db.example.test", hostaddr: "192.0.2.20", port: "5432", db: "synthetic")
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ double(ip_address: "192.0.2.20") ])
    allow(raw).to receive(:exec).and_return([ { "address" => "192.0.2.10", "port" => "5432", "database" => "synthetic" } ])
    expect { StagingDatabasePolicy.validate_live!(raw, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /backend is denied/)
    expect { StagingDatabasePolicy.validate_parameters!({ host: "staging-db.example.test", dbname: "other_database" }, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /clone identity/)
  end

  it "refuses ambiguous live connection identity" do
    raw = double(host: "staging-db.example.test,other", hostaddr: "", port: "5432", db: "synthetic")
    expect { StagingDatabasePolicy.validate_live!(raw, env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end
end
