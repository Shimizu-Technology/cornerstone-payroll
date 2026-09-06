# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe QuickbooksHistory::LifecycleService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Historical Import Concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, name: "Historical Import #{SecureRandom.hex(4)}") }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:first_batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
  end
  let!(:second_batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads(suffix: "changed"), actor: actor).call.batch
  end

  before do
    review_historical_workers_as_archive_only(first_batch, actor: actor)
    review_historical_workers_as_archive_only(second_batch, actor: actor)
  end

  after do
    HistoricalPaycheck.where(company_id: company.id).delete_all
    HistoricalPayPeriod.where(company_id: company.id).delete_all
    HistoricalWorker.where(company_id: company.id).delete_all
    HistoricalImportBatch.where(company_id: company.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
    cleanup_quickbooks_history_uploads
  end

  it "serializes competing applies before checking for overlapping paycheck snapshots" do
    first_checked = Queue.new
    release_first = Queue.new
    checked_once = false
    mutex = Mutex.new
    results = Queue.new

    allow_any_instance_of(described_class).to receive(:ensure_no_applied_duplicates!).and_wrap_original do |original|
      original.call
      pause = mutex.synchronize do
        next false if checked_once

        checked_once = true
      end
      if pause
        first_checked << true
        release_first.pop
      end
    end

    first = apply_thread(first_batch.id, results)
    first_checked.pop
    second = apply_thread(second_batch.id, results)
    expect { Timeout.timeout(0.2) { results.pop } }.to raise_error(Timeout::Error)
    release_first << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    outcomes = 2.times.map { results.pop }
    expect(outcomes.count { |status, _value| status == :ok }).to eq(1)
    errors = outcomes.filter_map { |status, value| value if status == :error }
    expect(errors).to contain_exactly(an_instance_of(ArgumentError))
    expect(errors.first.message).to match(/already exist in applied QuickBooks history/)
    expect(HistoricalImportBatch.where(id: [ first_batch.id, second_batch.id ], status: "applied").count).to eq(1)
  end

  private

  def apply_thread(batch_id, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        batch = HistoricalImportBatch.find(batch_id)
        thread_actor = User.find(actor.id)
        described_class.new(batch: batch, actor: thread_actor).apply!(
          acknowledgement: described_class::ACKNOWLEDGEMENT
        )
        results << [ :ok, batch_id ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
  end
end
