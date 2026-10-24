# frozen_string_literal: true

require "rails_helper"
require "active_support/testing/time_helpers"

RSpec.describe "durable staging receipt suppression" do
  include ActiveSupport::Testing::TimeHelpers
  around do |example|
    old = ENV.to_h
    StagingDatabasePolicy::ROUTING_ENV.each { |name| ENV.delete(name) }
    database = ActiveRecord::Base.connection_db_config.configuration_hash
    ENV["DEPLOYMENT_ENV"] = "staging"
    StagingOutboundPolicy::DATABASE_SETTINGS.each { |name| ENV.delete(name) }
    ENV["DATABASE_URL"] = URI::Generic.build(scheme: "postgresql", host: database.fetch(:host), port: database[:port], path: "/#{database.fetch(:database)}").to_s
    ENV["STAGING_DATABASE_HOSTS"] = database.fetch(:host)
    ENV["PRODUCTION_DATABASE_HOSTS"] = "production-db.example.test"
    ENV["STAGING_INTEGRATION_HOSTS"] = "time.example.com"
    ENV["PRODUCTION_INTEGRATION_HOSTS"] = "production-time.example.test"
    example.run
  ensure
    ENV.replace(old)
  end

  def source_import
    company = create(:company)
    period = create(:pay_period, company: company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied")
  end

  def batch_acknowledgement
    AirePayrollAcknowledgement.record!(time_tracking_import: source_import, status: "imported", occurred_at: Time.current)
  end

  def entry_acknowledgement
    import = source_import
    company = import.pay_period.company
    employee = create(:employee, company: company)
    item = create(:payroll_item, pay_period: import.pay_period, employee: employee)
    row = TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: import.time_tracking_source,
      time_tracking_import: import, pay_period: import.pay_period, payroll_item: item, employee: employee,
      source_user_id: "synthetic-worker", source_user_uuid: SecureRandom.uuid, source_time_entry_id: "synthetic-entry",
      line_key: "synthetic-line", source_kind: "current", original_work_date: import.start_date,
      total_hours: 8, regular_hours: 8, overtime_hours: 0)
    AirePayrollEntryAcknowledgement.record_from_rows!(rows: [ row ], source_event_key: SecureRandom.uuid,
      status: "imported", occurred_at: Time.current, payroll_item_id: item.id)
  end

  def bootstrap_dispatch
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    batch = create(:historical_import_batch, company: company, created_by: actor, status: "previewed")
    bootstrap = create(:historical_client_bootstrap, company: company, historical_import_batch: batch,
      created_by: actor, status: "pending", apply_started_at: Time.current)
    HistoricalClientBootstrapDispatch.create!(historical_client_bootstrap: bootstrap, requested_by: actor,
      attempt_token: bootstrap.apply_started_at.iso8601(6))
  end

  [ [ AirePayrollAcknowledgement, :batch_acknowledgement, AirePayrollStatusSyncJob ],
    [ AirePayrollEntryAcknowledgement, :entry_acknowledgement, AirePayrollEntryStatusSyncJob ],
    [ HistoricalClientBootstrapDispatch, :bootstrap_dispatch, QuickbooksHistory::ClientBootstrapJob ] ].each do |model, fixture, job|
    it "excludes real copied #{model.name} rows from discovery and direct dispatch while fresh rows dispatch" do
      copied = public_send(fixture)
      copied.update!(last_error: "Synthetic copied failure")
      before = copied.reload.attributes
      StagingCloneContainment.new.quarantine(apply: true)
      expect(StagingQuarantine.records.find_by!(source_table: model.table_name, source_id: copied.id)).to be_present
      fresh = public_send(fixture)
      discovered = []
      allow_any_instance_of(model).to receive(:dispatch!).and_wrap_original do |method, *args, **kwargs|
        discovered << method.receiver.id
        method.call(*args, **kwargs)
      end
      if model == HistoricalClientBootstrapDispatch
        expect(job).to receive(:perform_later).with(fresh.historical_client_bootstrap_id, fresh.requested_by_id, fresh.attempt_token).once
      else
        expect(job).to receive(:perform_later).with(fresh.id).once
      end
      model.dispatch_pending!
      expect(discovered).to eq([ fresh.id ])
      expect(fresh.reload.enqueued_at).to be_present
      expect(copied).not_to receive(:with_lock)
      expect(copied).not_to receive(:with_active_dispatch_lock) if model == HistoricalClientBootstrapDispatch
      expect(copied.dispatch!).to eq(false)
      expect(copied.reload.attributes).to eq(before)
    end
  end

  context "accounting-only correction receipts with verified frozen evidence" do
    include_context "exact source correction fixtures"

    it "holds the real copied receipt before discovery, locking or payload changes" do
      copied = confirm.time_tracking_correction_receipt
      copied.update!(last_error: "Synthetic copied correction failure")
      before = copied.reload.attributes
      StagingCloneContainment.new.quarantine(apply: true)
      expect(StagingQuarantine.records.find_by!(source_table: copied.class.table_name, source_id: copied.id)).to be_present
      expect(TimeTrackingCorrectionReceiptJob).not_to receive(:perform_later)
      discovered = []
      allow_any_instance_of(TimeTrackingCorrectionReceipt).to receive(:dispatch!).and_wrap_original do |method, *args, **kwargs|
        discovered << method.receiver.id
        method.call(*args, **kwargs)
      end
      TimeTrackingCorrectionReceipt.dispatch_pending!
      expect(discovered).to be_empty
      expect(copied).not_to receive(:with_lock)
      expect(copied.dispatch!(retry_failed: true)).to eq(false)
      expect(copied.reload.attributes).to eq(before)
    end

    it "discovers and dispatches a valid fresh correction receipt created after quarantine" do
      StagingCloneContainment.new.quarantine(apply: true)
      fresh = confirm.time_tracking_correction_receipt
      expect(StagingQuarantine.records.where(source_table: fresh.class.table_name, source_id: fresh.id)).not_to exist
      expect(TimeTrackingCorrectionReceiptJob).to receive(:perform_later).with(fresh.id).once
      travel_to(31.minutes.from_now) { TimeTrackingCorrectionReceipt.dispatch_pending! }
      expect(fresh.reload.enqueued_at).to be_present
      expect(fresh.last_error).to be_nil
      expect(fresh.payload.fetch("metadata")).to include("accounting_only" => true)
    end
  end

  context "financial correction retry" do
    include_context "exact source correction fixtures"
    let(:original_payment_state) { "unprepared" }
    let(:source) do
      create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
        expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
        source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1 payment_cancellation_v1], identity_verified_at: Time.current)
    end

    def financial_acknowledgement
      PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct the mistaken deduction")
      period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct the mistaken deduction")
      item = period.payroll_items.find_by!(employee: employee)
      PayrollCalculator.for(employee, item).calculate
      item.save!
      period.update!(status: "calculated")
      lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      item.aire_payroll_entry_acknowledgements.find_by!(status: "committed")
    end

    it "holds a copied financial retry before enqueue and preserves its error and timestamps" do
      copied = financial_acknowledgement
      expect(copied.financial_correction_link).to be_present
      copied.update!(last_error: "Synthetic retained source failure", enqueued_at: 1.hour.ago)
      before = copied.reload.attributes
      StagingCloneContainment.new.quarantine(apply: true)
      expect(StagingQuarantine.records.find_by!(source_table: copied.class.table_name, source_id: copied.id)).to be_present
      expect(AirePayrollEntryStatusSyncJob).not_to receive(:perform_later)
      expect(copied).not_to receive(:with_lock)
      expect(copied.retry_financial!).to eq(false)
      expect(copied.reload.attributes).to eq(before)
    end

    it "allows a new financial retry created after quarantine" do
      StagingCloneContainment.new.quarantine(apply: true)
      fresh = financial_acknowledgement
      fresh.update!(last_error: "Synthetic fresh source failure", enqueued_at: Time.current)
      expect(StagingQuarantine.records.where(source_table: fresh.class.table_name, source_id: fresh.id)).not_to exist
      expect(AirePayrollEntryStatusSyncJob).to receive(:perform_later).with(fresh.id).once
      expect(fresh.retry_financial!).to eq(true)
      expect(fresh.reload.last_error).to be_nil
    end
  end
end
