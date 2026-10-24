# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingCloneContainment do
  around do |example|
    old = ENV.to_h
    StagingDatabasePolicy::ROUTING_ENV.each { |name| ENV.delete(name) }
    ENV["DEPLOYMENT_ENV"] = "staging"
    # CI may supply DATABASE_URL or TEST_DATABASE_URL with a different host.
    database = ActiveRecord::Base.connection_db_config.configuration_hash
    StagingOutboundPolicy::DATABASE_SETTINGS.each { |name| ENV.delete(name) }
    ENV["DATABASE_URL"] = URI::Generic.build(scheme: "postgresql", host: database.fetch(:host), port: database[:port], path: "/#{database.fetch(:database)}").to_s
    ENV["STAGING_DATABASE_HOSTS"] = database.fetch(:host).downcase
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"},{"user_id":2,"email":"chels@example.test","clerk_subject":"user_chels"}]'
    ENV["STAGING_INTEGRATION_HOSTS"] = "aire-staging.example.test"
    ENV["PRODUCTION_INTEGRATION_HOSTS"] = "aire.example.test"
    ENV["STAGING_AIRE_FRONTEND_ORIGIN"] = "https://aire-web-staging.example.test"
    ENV["STAGING_PAYROLL_FRONTEND_ORIGIN"] = "https://payroll-web-staging.example.test"
    ENV["STAGING_AIRE_BASE_URL"] = "https://aire-staging.example.test"
    ENV["STAGING_PAYROLL_SHARED_SECRET"] = "n" * 64
    ENV["PAYROLL_SHARED_SECRET"] = "n" * 64
    example.run
  ensure
    ENV.replace(old)
  end

  it "refuses all clone operations outside staging" do
    ENV["DEPLOYMENT_ENV"] = "production"
    %i[quarantine configure counts].each do |operation|
      expect { described_class.new.public_send(operation) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    end
  end

  it "rejects a production host and an actual-connection mismatch" do
    ENV["PRODUCTION_DATABASE_HOSTS"] = ENV.fetch("STAGING_DATABASE_HOSTS")
    expect { described_class.new.quarantine(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    ENV["STAGING_DATABASE_HOSTS"] = "other-clone.example.test"
    ENV["DATABASE_URL"] = "postgresql://other-clone.example.test/test"
    expect { described_class.new.quarantine(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /Actual database/)
  end

  it "refuses a partial Solid Queue schema before any containment writes" do
    connection = ActiveRecord::Base.connection
    allow(connection).to receive(:data_source_exists?).and_call_original
    allow(connection).to receive(:data_source_exists?).with("solid_queue_scheduled_executions").and_return(false)
    expect(connection).not_to receive(:execute)
    expect { described_class.new.quarantine(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /complete Solid Queue schema/)
  end

  it "defaults to a read-only dry run with no DDL or record writes" do
    statements = []
    listener = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { described_class.new.quarantine }
    expect(statements.grep(/\A\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)/i)).to be_empty
  end

  it "quarantines copied jobs once, retaining the ID manifest and new staging jobs" do
    copied = SolidQueue::Job.create!(class_name: "ActionMailer::MailDeliveryJob", queue_name: "default", arguments: {}, active_job_id: SecureRandom.uuid)
    service = described_class.new
    service.quarantine(apply: true)
    expect(copied.reload.finished_at).to be_present
    expect(StagingQuarantine.suppressed?("solid_queue_jobs", copied.id)).to eq(true)
    fresh = SolidQueue::Job.create!(class_name: "SyntheticJob", queue_name: "default", arguments: {}, active_job_id: SecureRandom.uuid)
    service.quarantine(apply: true)
    expect(fresh.reload.finished_at).to be_nil
    expect(StagingQuarantine.suppressed?("solid_queue_jobs", fresh.id)).to eq(false)
  end

  it "makes no tester binding writes when provider identity proof fails" do
    leon = create(:user, email: "leon@example.test")
    chels = create(:user, email: "chels@example.test")
    original = [ leon.clerk_id, chels.clerk_id ]
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: leon.id, email: leon.email, clerk_subject: "user_leon" }, { user_id: chels.id, email: chels.email, clerk_subject: "user_chels" } ].to_json
    ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
    allow(HTTParty).to receive(:get).and_return(double(success?: true, parsed_response: { "id" => "user_leon", "primary_email_address_id" => "primary", "email_addresses" => [ { "id" => "primary", "email_address" => "outsider@example.test", "verification" => { "status" => "verified" } } ] }))
    service = described_class.new
    service.quarantine(apply: true)
    expect { service.configure(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /verified primary/)
    expect([ leon.reload.clerk_id, chels.reload.clerk_id ]).to eq(original)
    expect(StagingQuarantine.complete?).to eq(false)
  end

  it "rebinds the two existing tester identities, preserves local IDs, and is repeatable" do
    leon = create(:user, email: "leon@example.test")
    chels = create(:user, email: "chels@example.test")
    original_ids = [ leon.id, chels.id ]
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: leon.id, email: leon.email, clerk_subject: "user_leon" }, { user_id: chels.id, email: chels.email, clerk_subject: "user_chels" } ].to_json
    allow(StagingTesterIdentity).to receive(:verify!).and_return(StagingOutboundPolicy.tester_records)
    service = described_class.new
    service.quarantine(apply: true)
    service.configure(apply: true)
    service.configure(apply: true)
    expect([ leon.reload.id, chels.reload.id ]).to eq(original_ids)
    expect([ leon.clerk_id, chels.clerk_id ]).to eq(%w[user_leon user_chels])
    expect(StagingQuarantine.complete?).to eq(true)
  end

  it "holds configuration until the quarantined production schema has been migrated" do
    create(:user, email: "leon@example.test")
    create(:user, email: "chels@example.test")
    service = described_class.new
    service.quarantine(apply: true)
    allow(TimeTrackingSource).to receive(:column_names).and_return([ "id", "base_url", "shared_secret" ])
    expect { service.configure(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /Migrate the quarantined clone/)
    expect(StagingQuarantine.complete?).to eq(false)
  end

  it "holds direct historical bootstrap execution from the copied manifest" do
    allow(StagingQuarantine).to receive(:suppressed?).with("historical_client_bootstraps", 123).and_return(true)
    expect(HistoricalClientBootstrap).not_to receive(:find)
    QuickbooksHistory::ClientBootstrapJob.new.perform(123, 1, "copied-attempt")
  end
end
