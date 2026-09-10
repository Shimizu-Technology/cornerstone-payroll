# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Time tracking source deactivation", :postgres_concurrency, type: :service do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: company, organization: organization) }
  let!(:period) { create(:pay_period, company: company) }
  let!(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:import) { create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source) }

  after do
    TimeTrackingImport.where(id: import.id).delete_all
    TimeTrackingSource.where(id: source.id).delete_all
    PayPeriod.where(id: period.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  [ :apply, :reconcile ].each do |operation|
    it "waits for deactivation to commit before rejecting #{operation} with a stale active source" do
      period.update!(status: "committed") if operation == :reconcile
      # Build the service before deactivation so its cached association is active.
      service = if operation == :apply
        TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor)
      else
        TimeTracking::ReconcileCommittedImportService.new(
          import: import, mappings: [], reconciled_by: actor, reconciliation_note: "Reviewed saved payroll."
        )
      end
      backend = Queue.new
      outcome = Queue.new
      worker = nil

      begin
        source.with_lock do
          source.update!(active: false)
          worker = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do |connection|
              backend << connection.select_value("SELECT pg_backend_pid()")
              service.call
              outcome << :unexpected_success
            rescue StandardError => error
              outcome << error
            end
          end

          pid = backend.pop(timeout: 10) || raise(Timeout::Error, "Worker did not start")
          Timeout.timeout(10) do
            until ApplicationRecord.connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(pid)} AND NOT granted)")
              sleep 0.01
            end
          end
          expect(outcome).to be_empty
        end
      ensure
        Timeout.timeout(10) { worker.join } if worker
      end

      error = outcome.pop(timeout: 10)
      expect(error).to be_a(ArgumentError)
      expect(error.message).to eq("Time tracking source is inactive")
      expect(import.reload).to have_attributes(status: "previewed", applied_at: nil, reconciled_at: nil)
      expect(period.payroll_items).to be_empty
      expect(TimeTrackingEntryAllocation.where(time_tracking_import_id: import.id)).to be_empty
      expect(AirePayrollAcknowledgement.where(time_tracking_import_id: import.id)).to be_empty
    end
  end
end
