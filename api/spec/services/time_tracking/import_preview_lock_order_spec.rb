# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Time import/rollout lock ordering", :postgres_concurrency, type: :model do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Import lock ordering #{SecureRandom.uuid}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:source) { create(:time_tracking_source, company: company) }
  let!(:period) { create(:pay_period, company: company) }

  after do
    TimeTrackingImport.where(time_tracking_source_id: source.id).delete_all
    period.destroy!
    source.destroy!
    company.destroy!
    FinanceBook.where(organization_id: organization.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  [ :finalized, :legacy ].each do |kind|
    it "waits for the source before touching the import table for #{kind} persistence" do
      writer_pid, result = Queue.new, Queue.new
      writer = nil
      source.with_lock do
        writer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            writer_pid << connection.raw_connection.backend_pid
            instance = (kind == :finalized ? TimeTracking::BatchImportPreviewService : TimeTracking::ImportPreviewService)
              .new(pay_period: PayPeriod.find(period.id), source: TimeTrackingSource.find(source.id))
            saved = if kind == :finalized
              instance.send(:persist_preview!, { "batch_id" => "SYNTHETIC-#{SecureRandom.uuid}", "schema_version" => "2.0",
                "cutoff_at" => "2026-08-31T00:00:00Z", "export" => { "checksum" => "a" * 64 } }, {}, [])
            else
              instance.send(:save_preview_import!, lookup_attrs: { pay_period: instance.pay_period,
                time_tracking_source: instance.source, start_date: period.start_date, end_date: period.end_date, source_payload_hash: "b" * 64 },
                import_attrs: { status: "previewed", fetch_start_date: period.start_date, fetch_end_date: period.end_date,
                  raw_payload: {}, processed_payload: {}, warnings: [] })
            end
            result << saved.id
          rescue StandardError => error
            result << error
          end
        end
        pid = Timeout.timeout(10) { writer_pid.pop }
        Timeout.timeout(10) do
          loop do
            ActiveRecord::Base.connection.execute("SELECT pg_stat_clear_snapshot()")
            waiting = ActiveRecord::Base.uncached do
              ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
            end
            break if waiting == "Lock"
            sleep 0.01
          end
        end
        # Configure owns this source and must acquire this SHARE lock next.
        # A writer that INSERTed before taking the source owns ROW EXCLUSIVE
        # here and makes this NOWAIT fail (or creates a real deadlock).
        ActiveRecord::Base.connection.execute("LOCK TABLE time_tracking_imports IN SHARE MODE NOWAIT")
        expect(result).to be_empty
      end
      Timeout.timeout(10) { writer.join }
      saved = result.pop
      expect(saved).to be_a(Integer), saved.inspect
      expect(TimeTrackingImport.find(saved).time_tracking_source_id).to eq(source.id)
    ensure
      Timeout.timeout(10) { writer&.join }
    end
  end
end
