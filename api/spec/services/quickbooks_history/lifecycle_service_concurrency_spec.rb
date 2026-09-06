# frozen_string_literal: true

require "rails_helper"
require "timeout"

module QuickbooksHistoryLifecycleConcurrencyHook
  def ensure_no_applied_duplicates!
    super
    Thread.current[:quickbooks_history_after_duplicate_check]&.call
  end
end

QuickbooksHistory::LifecycleService.prepend(QuickbooksHistoryLifecycleConcurrencyHook) unless
  QuickbooksHistory::LifecycleService < QuickbooksHistoryLifecycleConcurrencyHook

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
    results = Queue.new
    pause_after_duplicate_check = lambda do
      first_checked << true
      pop_with_timeout(release_first)
    end

    first = apply_thread(first_batch.id, results, after_duplicate_check: pause_after_duplicate_check)
    pop_with_timeout(first_checked)
    second = apply_thread(second_batch.id, results)
    expect { Timeout.timeout(0.2) { results.pop } }.to raise_error(Timeout::Error)
    release_first << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    outcomes = 2.times.map { pop_with_timeout(results) }
    expect(outcomes.count { |status, _value| status == :ok }).to eq(1)
    errors = outcomes.filter_map { |status, value| value if status == :error }
    expect(errors).to contain_exactly(an_instance_of(ArgumentError))
    expect(errors.first.message).to match(/already exist in applied QuickBooks history/)
    expect(HistoricalImportBatch.where(id: [ first_batch.id, second_batch.id ], status: "applied").count).to eq(1)
  end

  it "rejects an update from a stale batch after another connection locks it" do
    stale_batch = HistoricalImportBatch.find(first_batch.id)
    results = Queue.new
    thread = apply_and_lock_thread(first_batch.id, results)
    Timeout.timeout(10) { thread.join }
    expect(pop_with_timeout(results)).to eq([ :ok, first_batch.id ])

    expect(stale_batch.update(source_label: "Stale metadata")).to be(false)
    expect(stale_batch.errors.full_messages).to include("Locked historical imports cannot be changed")
  end

  it "rejects a stale worker update after another connection locks its batch" do
    stale_worker = first_batch.historical_workers.first
    results = Queue.new
    thread = apply_and_lock_thread(first_batch.id, results)
    Timeout.timeout(10) { thread.join }
    expect(pop_with_timeout(results)).to eq([ :ok, first_batch.id ])

    expect(stale_worker.update(source_name: "Stale worker")).to be(false)
    expect(stale_worker.errors.full_messages).to include("Historical workers can only be changed while the batch is a preview")
  end

  private

  def pop_with_timeout(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def apply_thread(batch_id, results, after_duplicate_check: nil)
    Thread.new do
      Thread.current[:quickbooks_history_after_duplicate_check] = after_duplicate_check
      ActiveRecord::Base.connection_pool.with_connection do
        batch = HistoricalImportBatch.find(batch_id)
        thread_actor = User.find(actor.id)
        described_class.new(batch: batch, actor: thread_actor).apply!(
          acknowledgement: described_class::ACKNOWLEDGEMENT
        )
        results << [ :ok, batch_id ]
      rescue StandardError => e
        results << [ :error, e ]
      ensure
        Thread.current[:quickbooks_history_after_duplicate_check] = nil
      end
    end
  end

  def apply_and_lock_thread(batch_id, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        batch = HistoricalImportBatch.find(batch_id)
        thread_actor = User.find(actor.id)
        service = described_class.new(batch: batch, actor: thread_actor)
        service.apply!(acknowledgement: described_class::ACKNOWLEDGEMENT)
        service.lock!
        results << [ :ok, batch_id ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
  end
end
