# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingCloneContainment do
  around do |example|
    old = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_DATABASE_HOSTS"] = "127.0.0.1"
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    ENV["STAGING_TESTER_BINDINGS"] = '{"leon@example.test":"user_leon","chels@example.test":"user_chels"}'
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
    ENV["PRODUCTION_DATABASE_HOSTS"] = "127.0.0.1"
    expect { described_class.new.quarantine(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    ENV["STAGING_DATABASE_HOSTS"] = "other-clone.example.test"
    ENV["DATABASE_URL"] = "postgresql://other-clone.example.test/test"
    expect { described_class.new.quarantine(apply: true) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /Actual database/)
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

  it "rebinds the two existing tester identities, preserves local IDs, and is repeatable" do
    leon = create(:user, email: "leon@example.test")
    chels = create(:user, email: "chels@example.test")
    original_ids = [ leon.id, chels.id ]
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
