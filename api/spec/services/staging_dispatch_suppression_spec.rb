# frozen_string_literal: true

require "rails_helper"

RSpec.describe "durable staging dispatch suppression" do
  around do |example|
    old = ENV.to_h
    StagingDatabasePolicy::ROUTING_ENV.each { |name| ENV.delete(name) }
    database = ActiveRecord::Base.connection_db_config.configuration_hash
    ENV["DEPLOYMENT_ENV"] = "staging"
    StagingOutboundPolicy::DATABASE_SETTINGS.each { |name| ENV.delete(name) }
    ENV["DATABASE_URL"] = URI::Generic.build(scheme: "postgresql", host: database.fetch(:host), port: database[:port], path: "/#{database.fetch(:database)}").to_s
    ENV["STAGING_DATABASE_HOSTS"] = database.fetch(:host)
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    example.run
  ensure
    ENV.replace(old)
  end

  def publication
    deployment = ENV.delete("DEPLOYMENT_ENV")
    create(:aire_payroll_calendar_publication)
  ensure
    ENV["DEPLOYMENT_ENV"] = deployment
  end

  def event_for(publication)
    payload = { "synthetic" => true }
    AirePayrollEvent.create!(aire_payroll_calendar_period: publication.aire_payroll_calendar_period,
      aire_payroll_calendar_publication: publication, time_tracking_source: publication.aire_payroll_calendar_period.time_tracking_source,
      event_id: SecureRandom.uuid, event_type: AirePayrollEvent::EVENT_TYPE, occurred_at: Time.current,
      payload: payload, payload_checksum: TimeTracking::CanonicalPayload.checksum(payload), payroll_batch_id: SecureRandom.uuid, payroll_batch_checksum: "a" * 64)
  end

  it "manifests copied verification events and holds discovery, direct dispatch, job and verifier" do
    copied = event_for(publication)
    StagingCloneContainment.new.quarantine(apply: true)
    fresh = event_for(publication)
    expect(StagingQuarantine.records.find_by!(source_table: "aire_payroll_events", source_id: copied.id).original_state).to eq("pending")
    queued = []
    AirePayrollEvent.dispatch_due!(enqueue: ->(id) { queued << id })
    expect(queued).to eq([ fresh.id ])
    expect(AirePayrollEvent.dispatch_one!(copied.id, enqueue: ->(*) { raise "copied dispatch escaped" })).to eq(false)
    expect(AirePayrollEvents::Verifier.new(event_id: copied.id).call).to include(status: "quarantined")
    expect(AirePayrollEvents::Verifier).not_to receive(:new)
    AirePayrollEventVerificationJob.new.perform(copied.id)
    expect(StagingCloneContainment.new.counts.fetch("aire_payroll_events")).to include(quarantined: 1)
  end

  it "uses real manifest rows to exclude joined dispatch relations" do
    copied = publication
    StagingCloneContainment.new.quarantine(apply: true)
    fresh = publication
    scope = AirePayrollCalendarPublication.joins(:aire_payroll_calendar_period)
    expect(StagingQuarantine.excluding(scope).pluck(:id)).to eq([ fresh.id ])
    expect(AirePayrollCalendarPublication.dispatch_one!(copied.id)).to eq(false)
    expect(AirePayrollCalendar::Delivery.new(publication_id: copied.id).call).to include(status: "quarantined")
  end

  it "enqueues only the fresh due calendar publication after clone quarantine" do
    copied = publication
    copied.update!(next_delivery_attempt_at: 1.minute.ago)
    StagingCloneContainment.new.quarantine(apply: true)
    fresh = publication
    fresh.update!(next_delivery_attempt_at: 1.minute.ago)
    expect(StagingQuarantine.records.where(source_table: copied.class.table_name, source_id: copied.id)).to exist
    expect(AirePayrollCalendarPublication.due_for_delivery).to contain_exactly(copied, fresh)

    queued = []
    dispatched = AirePayrollCalendarPublication.dispatch_due!(enqueue: ->(id) { queued << id })

    expect(dispatched).to eq([ fresh.id ])
    expect(queued).to eq([ fresh.id ])
    expect(copied.reload.delivery_enqueued_until).to be_nil
    expect(fresh.reload.delivery_enqueued_until).to be_present
  end

  it "returns before each copied receipt job loads its record" do
    StagingCloneContainment.new.quarantine(apply: true)
    [ [ AirePayrollStatusSyncJob, AirePayrollAcknowledgement ], [ AirePayrollEntryStatusSyncJob, AirePayrollEntryAcknowledgement ], [ TimeTrackingCorrectionReceiptJob, TimeTrackingCorrectionReceipt ] ].each do |job, model|
      StagingQuarantine.records.create!(source_table: model.table_name, source_id: 123)
      expect(model).not_to receive(:includes)
      expect(model).not_to receive(:find)
      job.new.perform(123)
    end
  end
end
