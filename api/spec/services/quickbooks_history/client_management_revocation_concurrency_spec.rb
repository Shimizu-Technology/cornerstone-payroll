# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Client management revocation while a business lock is held", :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: :org_admin) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let!(:assignment) { create(:company_assignment, user: actor, company: company, granted_by: admin, client_management: true) }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
  end

  after do
    HistoricalPaycheck.where(company_id: company.id).delete_all
    HistoricalPayPeriod.where(company_id: company.id).delete_all
    HistoricalWorker.where(company_id: company.id).delete_all
    HistoricalImportSourceFile.where(historical_import_batch_id: batch.id).delete_all
    HistoricalImportBatch.where(id: batch.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    CompanyAssignment.where(company_id: company.id).delete_all
    User.where(id: [ actor.id, admin.id ]).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: company.organization_id).delete_all
  end

  it "denies a previously authorized mapping after an administrator commits revocation during its real PostgreSQL lock wait" do
    waiting = Queue.new
    result = Queue.new
    worker_id = batch.historical_workers.first.id
    audits_before = AuditLog.where(company_id: company.id).count
    connection = ActiveRecord::Base.connection
    thread = nil

    HistoricalImportBatch.transaction do
      batch.lock!
      allow_any_instance_of(HistoricalImportBatch).to receive(:lock!).and_wrap_original do |original, *args|
        waiting << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
        original.call(*args)
      end
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          worker = HistoricalWorker.find(worker_id)
          QuickbooksHistory::MappingService.new(worker: worker, employee: nil, actor: User.find(actor.id), archive_only: true).call
          result << :unexpected_success
        rescue StandardError => e
          result << e
        end
      end
      blocked_pid = Timeout.timeout(10) { waiting.pop }
      Timeout.timeout(10) do
        until connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(blocked_pid)})) > 0")
          sleep 0.01
        end
      end
      assignment.update!(client_management: false)
    end
    Timeout.timeout(10) { thread.join }

    outcome = result.pop
    expect(outcome).to be_a(ArgumentError)
    expect(outcome.message).to include("company access")
    expect(assignment.reload.client_management).to be(false)
    expect(HistoricalWorker.find(worker_id)).to have_attributes(mapping_status: "needs_review", employee_id: nil)
    expect(batch.historical_paychecks.distinct.pluck(:employee_id)).to eq([ nil ])
    expect(AuditLog.where(company_id: company.id).count).to eq(audits_before)
  ensure
    Timeout.timeout(10) { thread&.join }
  end
end
