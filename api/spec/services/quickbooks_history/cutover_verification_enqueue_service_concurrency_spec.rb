# frozen_string_literal: true

require "rails_helper"
require "timeout"

module QuickbooksHistoryCutoverEnqueueConcurrencyHook
  def record_audit!(review, action)
    Thread.current[:quickbooks_history_cutover_enqueue_locked]&.call if action == "historical_imports#queue_cutover_verification"
    super
  end
end

QuickbooksHistory::CutoverVerificationEnqueueService.prepend(QuickbooksHistoryCutoverEnqueueConcurrencyHook) unless
  QuickbooksHistory::CutoverVerificationEnqueueService < QuickbooksHistoryCutoverEnqueueConcurrencyHook

RSpec.describe QuickbooksHistory::CutoverVerificationEnqueueService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Cutover Enqueue Concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:batch) do
    HistoricalImportBatch.create!(
      company: company,
      created_by: actor,
      applied_by: actor,
      source_label: "Concurrent cutover verification",
      bundle_digest: Digest::SHA256.hexdigest(SecureRandom.hex(16)),
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION,
      status: "applied",
      applied_at: Time.current
    )
  end

  before do
    @enqueued_jobs = Queue.new
    allow(QuickbooksHistory::CutoverVerificationJob).to receive(:perform_later) do |*arguments|
      @enqueued_jobs << arguments
      true
    end
  end

  after do
    HistoricalImportCutoverReview.where(historical_import_batch_id: batch.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    HistoricalImportBatch.where(id: batch.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "enqueues only one job when two verification requests contend on the batch lock" do
    first_locked = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    results = Queue.new
    pause_while_locked = lambda do
      first_locked << true
      pop_with_timeout(release_first)
    end

    first = enqueue_thread(batch.id, results, while_locked: pause_while_locked)
    pop_with_timeout(first_locked)
    second = enqueue_thread(batch.id, results, on_start: -> { second_started << true })
    pop_with_timeout(second_started)
    expect { pop_with_timeout(results, seconds: 0.2) }.to raise_error(Timeout::Error)

    release_first << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    outcomes = 2.times.map { pop_with_timeout(results) }
    expect(outcomes).to contain_exactly([ :ok, true ], [ :ok, false ])
    expect(@enqueued_jobs.size).to eq(1)
    expect(HistoricalImportCutoverReview.where(historical_import_batch_id: batch.id).count).to eq(1)
  end

  private

  def pop_with_timeout(queue, seconds: 10)
    queue.pop(timeout: seconds) || raise(Timeout::Error, "Timed out waiting for a queue value")
  rescue ThreadError
    raise Timeout::Error, "Timed out waiting for a queue value"
  end

  def enqueue_thread(batch_id, results, while_locked: nil, on_start: nil)
    Thread.new do
      Thread.current[:quickbooks_history_cutover_enqueue_locked] = while_locked
      ActiveRecord::Base.connection_pool.with_connection do
        on_start&.call
        thread_batch = HistoricalImportBatch.find(batch_id)
        thread_actor = User.find(actor.id)
        result = described_class.new(batch: thread_batch, actor: thread_actor).call
        results << [ :ok, result.enqueued ]
      rescue StandardError => e
        results << [ :error, e ]
      ensure
        Thread.current[:quickbooks_history_cutover_enqueue_locked] = nil
      end
    end
  end
end
