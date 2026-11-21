# frozen_string_literal: true

require "rails_helper"

# Two real database connections: an import saving its rows while another
# refresh is being reserved for the same organization. Both take the
# organization row first, then the import row, so the reservation waits for
# the save instead of deadlocking.
RSpec.describe "Tax work hours import lock order" do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }

  after do
    ids = WorkHourImport.where(organization_id: organization.id).pluck(:id)
    WorkHourRow.where(work_hour_import_id: ids).delete_all
    WorkHourImport.where(id: ids).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "makes a reservation wait for a save in progress instead of deadlocking" do
    import = WorkHourImport.reserve!(organization: organization, trigger: "manual",
                                     range_start: Date.new(2026, 10, 1), range_end: Date.new(2026, 10, 31))
    saving = Queue.new
    competitor_locked = Queue.new
    allow(WorkHourRow).to receive(:insert_all!).and_wrap_original do |original, *args|
      saving << true
      # Give the competitor time to try for the organization lock. It must
      # not get it while this save holds it.
      competitor_locked.pop(timeout: 1.5)
      original.call(*args)
    end

    competitor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        saving.pop
        local = Organization.find(organization.id)
        local.define_singleton_method(:lock!) { |*args| super(*args).tap { competitor_locked << true } }
        WorkHourImport.reserve!(organization: local, trigger: "manual", range_start: import.range_start, range_end: import.range_end)
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
    reserved = competitor.value

    expect(result.status).to eq("succeeded")
    expect(reserved).to be_a(WorkHourImport) # it got in once the save committed
    expect(reserved.status).to eq("queued")
    expect(WorkHourRow.where(organization_id: organization.id).count).to eq(1)
  end
end
