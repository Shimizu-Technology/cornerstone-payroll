# frozen_string_literal: true

require "rails_helper"

# Two real database connections: an import saving its rows while another
# refresh is being reserved for the same organization. Both take the
# organization row first, then the import row, so the reservation waits for
# the save instead of deadlocking.
#
# The test does not rely on timing. The save pauses inside its transaction
# until PostgreSQL itself reports the competitor blocked on the organization
# row (a tuple lock on organizations while it waits). If that never happens
# before the deadline, for example because the save no longer locks the
# organization first, the test fails.
RSpec.describe "Tax work hours import lock order" do
  self.use_transactional_tests = false

  def deadline_seconds
    10
  end

  let!(:organization) { create(:organization) }

  after do
    ids = WorkHourImport.where(organization_id: organization.id).pluck(:id)
    WorkHourRow.where(work_hour_import_id: ids).delete_all
    WorkHourImport.where(id: ids).delete_all
    Organization.where(id: organization.id).delete_all
  end

  def blocked_on_organization_row?(connection, pid)
    connection.select_value(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, pid ]))
      SELECT a.wait_event_type = 'Lock' AND EXISTS (
               SELECT 1 FROM pg_locks l
               WHERE l.pid = a.pid AND l.locktype = 'tuple' AND l.relation = 'organizations'::regclass)
      FROM pg_stat_activity a WHERE a.pid = ?
    SQL
  end

  def pop_by_deadline(queue, what)
    queue.pop(timeout: deadline_seconds) || raise("timed out waiting for #{what}")
  end

  it "makes a reservation wait for a save in progress instead of deadlocking" do
    import = WorkHourImport.reserve!(organization: organization, trigger: "manual",
                                     range_start: Date.new(2026, 10, 1), range_end: Date.new(2026, 10, 31))
    saving = Queue.new
    competitor_pid = Queue.new
    blocked_seen = false
    allow(WorkHourRow).to receive(:insert_all!).and_wrap_original do |original, *args|
      # The save holds the organization and import rows now. Let the
      # competitor try to reserve, and wait until the database shows it
      # blocked on the organization row.
      saving << true
      pid = pop_by_deadline(competitor_pid, "the competitor to start")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
      until (blocked_seen = blocked_on_organization_row?(WorkHourRow.connection, pid))
        raise "the competitor was never blocked on the organization row" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
      original.call(*args)
    end

    competitor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pop_by_deadline(saving, "the save to start") # barrier: the save is in its transaction
        competitor_pid << connection.select_value("SELECT pg_backend_pid()")
        WorkHourImport.reserve!(organization: Organization.find(organization.id), trigger: "manual",
                                range_start: import.range_start, range_end: import.range_end)
      rescue StandardError => e
        e
      end
    end

    feed = Object.new
    def feed.fetch(start_date:, end_date:)
      { "schema_version" => "1.0", "counts" => {},
        "rows" => [ { "tax_user_id" => 12, "work_date" => start_date.iso8601, "client_id" => 42, "client_name" => "Synthetic",
                      "unassigned" => false, "hours" => 8, "approval_state" => "approved" } ] }
    end
    result = TaxWorkHours::Importer.call(import, client: feed)
    reserved = competitor.join(deadline_seconds)&.value
    raise "the competitor never finished" unless reserved

    expect(blocked_seen).to be(true)
    expect(result.status).to eq("succeeded")
    expect(reserved).to be_a(WorkHourImport) # it got in once the save committed
    expect(reserved.status).to eq("queued")
    expect(WorkHourRow.where(organization_id: organization.id).count).to eq(1)
  end
end
