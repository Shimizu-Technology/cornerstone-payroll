# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxWorkHours::Importer do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }

  def row(work_date, hours: 1.5, client_id: 345, client_name: "Example Co", approval_state: "approved", **extra)
    { "tax_user_id" => 12, "email" => "Staff@Example.com", "work_date" => work_date, "client_id" => client_id,
      "client_name" => client_name, "system_kind" => nil, "unassigned" => client_id.nil?, "category_id" => 3,
      "category" => "Bookkeeping", "task_id" => nil, "task" => nil, "period_type" => nil, "period_start" => nil,
      "period_label" => nil, "hours" => hours, "minutes" => (hours * 60).round, "entry_ids" => [ 1 ],
      "approval_state" => approval_state }.merge(extra.stringify_keys)
  end

  def payload(rows, pending: 0)
    { "schema_version" => "1.0", "generated_at" => "2026-11-30T01:00:00Z", "rows" => rows,
      "counts" => { "pending_entries" => pending, "denied_entries" => 0, "open_clock_entries" => 1 } }
  end

  # Answers each requested month from a hash keyed by [start, end].
  class FakeFeed
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def fetch(start_date:, end_date:)
      @requests << [ start_date, end_date ]
      response = @responses.fetch([ start_date, end_date ])
      raise response if response.is_a?(Exception)

      response
    end
  end

  def import_for(first, last)
    WorkHourImport.create!(organization: organization, range_start: first, range_end: last, lease_expires_at: 15.minutes.from_now)
  end

  # Answers with a block so a test can act while a fetch is "in flight".
  class InterleavedFeed
    def initialize(&block)
      @block = block
    end

    def fetch(start_date:, end_date:)
      @block.call(start_date, end_date)
    end
  end

  it "never lets a superseded worker overwrite newer hours (deterministic interleaving)" do
    november = [ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ]
    slow = import_for(*november)
    # Worker A claims the import and starts fetching. While its request is in
    # flight its lease runs out, worker B takes the import over, fetches newer
    # hours (8h) and commits. Then A's stale answer (1h) arrives.
    stale_feed = InterleavedFeed.new do
      travel(WorkHourImport::RUNNING_LEASE + 1.minute) do
        newer = FakeFeed.new(november => payload([ row("2026-11-02", hours: 8) ]))
        expect(described_class.call(slow, client: newer).status).to eq("succeeded")
      end
      payload([ row("2026-11-02", hours: 1) ])
    end
    result = described_class.call(slow, client: stale_feed)

    expect(result.status).to eq("succeeded")
    expect(WorkHourRow.pluck(:hours)).to eq([ 8.to_d ])
  end

  it "refuses to commit once it no longer holds the claim, even after fetching every month" do
    import = import_for(Date.new(2026, 11, 1), Date.new(2026, 11, 30))
    importer = described_class.new(import, client: FakeFeed.new([ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([ row("2026-11-02") ])))
    allow(import).to receive(:renew_lease!).and_wrap_original do |original, token|
      result = original.call(token)
      WorkHourImport.where(id: import.id).update_all(claim_token: "someone-else") # taken over after the last renewal
      result
    end
    importer.call
    expect(WorkHourRow.count).to eq(0)
    expect(import.reload).to have_attributes(status: "running", claim_token: "someone-else")
  end

  it "lets exactly one worker claim an import" do
    import = import_for(Date.new(2026, 11, 1), Date.new(2026, 11, 30))
    first = WorkHourImport.find(import.id).claim!
    second = WorkHourImport.find(import.id).claim!
    expect(first).to be_present
    expect(second).to be_nil
  end

  it "pulls one calendar month per request and stores normalized rows" do
    feed = FakeFeed.new(
      [ Date.new(2026, 10, 15), Date.new(2026, 10, 31) ] => payload([ row("2026-10-20") ], pending: 2),
      [ Date.new(2026, 11, 1), Date.new(2026, 11, 20) ] => payload([ row("2026-11-03", hours: 2.25, client_id: nil, client_name: "Unassigned") ])
    )
    import = described_class.call(import_for(Date.new(2026, 10, 15), Date.new(2026, 11, 20)), client: feed)

    expect(feed.requests).to eq([ [ Date.new(2026, 10, 15), Date.new(2026, 10, 31) ], [ Date.new(2026, 11, 1), Date.new(2026, 11, 20) ] ])
    expect(import.reload).to have_attributes(status: "succeeded", row_count: 2, total_hours: 3.75.to_d, pending_entries: 2,
                                             open_clock_entries: 2, schema_version: "1.0")
    stored = WorkHourRow.order(:work_date)
    expect(stored.first).to have_attributes(email: "staff@example.com", tax_client_id: 345, unassigned: false, hours: 1.5.to_d)
    expect(stored.last).to have_attributes(tax_client_id: nil, unassigned: true, client_name: "Unassigned")
  end

  it "replaces only the pulled range, and keeps everything when any month fails" do
    feed = FakeFeed.new([ Date.new(2026, 10, 1), Date.new(2026, 10, 31) ] => payload([ row("2026-10-01"), row("2026-10-31") ]),
                        [ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([ row("2026-11-30") ]))
    described_class.call(import_for(Date.new(2026, 10, 1), Date.new(2026, 11, 30)), client: feed)
    expect(WorkHourRow.count).to eq(3)

    refreshed = FakeFeed.new([ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([ row("2026-11-02", hours: 4) ]))
    described_class.call(import_for(Date.new(2026, 11, 1), Date.new(2026, 11, 30)), client: refreshed)
    expect(WorkHourRow.order(:work_date).pluck(:work_date, :hours))
      .to eq([ [ Date.new(2026, 10, 1), 1.5.to_d ], [ Date.new(2026, 10, 31), 1.5.to_d ], [ Date.new(2026, 11, 2), 4.to_d ] ])

    failing = FakeFeed.new([ Date.new(2026, 10, 1), Date.new(2026, 10, 31) ] => payload([]),
                           [ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => TaxWorkHours::Error.new("unauthorized"))
    failed = described_class.call(import_for(Date.new(2026, 10, 1), Date.new(2026, 11, 30)), client: failing)
    expect(failed.reload).to have_attributes(status: "failed", error_code: "unauthorized")
    expect(failed.error_message).to match(/signature/)
    expect(WorkHourRow.count).to eq(3)
  end

  it "ignores rows outside the month that was asked for" do
    feed = FakeFeed.new([ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([ row("2026-11-05"), row("2026-12-01") ]))
    described_class.call(import_for(Date.new(2026, 11, 1), Date.new(2026, 11, 30)), client: feed)
    expect(WorkHourRow.pluck(:work_date)).to eq([ Date.new(2026, 11, 5) ])
  end

  it "keeps another organization's hours untouched" do
    other = create(:organization)
    other_import = WorkHourImport.create!(organization: other, range_start: Date.new(2026, 11, 1), range_end: Date.new(2026, 11, 30))
    feed = FakeFeed.new([ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([ row("2026-11-05") ]))
    described_class.call(other_import, client: feed)
    described_class.call(import_for(Date.new(2026, 11, 1), Date.new(2026, 11, 30)),
                         client: FakeFeed.new([ Date.new(2026, 11, 1), Date.new(2026, 11, 30) ] => payload([])))
    expect(WorkHourRow.where(organization: other).count).to eq(1)
  end
end

RSpec.describe TaxWorkHoursNightlyRefreshJob do
  it "does nothing while Tax isn't connected, even for an organization that is set up" do
    company = create(:company)
    ClientProfitabilitySetting.create!(organization: company.organization, practice_company: company)
    allow(TaxWorkHours::Configuration).to receive(:current).and_return(TaxWorkHours::Configuration.new(base_url: nil, secret: nil))
    allow(TaxWorkHours::Importer).to receive(:call)
    expect { described_class.perform_now }.not_to change(WorkHourImport, :count)
    expect(TaxWorkHours::Importer).not_to have_received(:call)
  end

  it "skips an organization whose manual refresh is running, through the same reservation" do
    company = create(:company)
    ClientProfitabilitySetting.create!(organization: company.organization, practice_company: company)
    manual = WorkHourImport.reserve!(organization: company.organization, trigger: "manual",
                                     range_start: Date.new(2026, 11, 1), range_end: Date.new(2026, 11, 21))
    allow(TaxWorkHours::Configuration).to receive(:current)
      .and_return(TaxWorkHours::Configuration.new(base_url: "https://tax.example.test", secret: "x"))
    allow(TaxWorkHours::Importer).to receive(:call)
    expect { described_class.perform_now(today: Date.new(2026, 11, 21)) }.not_to change(WorkHourImport, :count)
    expect(TaxWorkHours::Importer).not_to have_received(:call)
    expect(manual.reload.status).to eq("queued")
  end

  it "refreshes last month through today for organizations with a practice company" do
    company = create(:company)
    ClientProfitabilitySetting.create!(organization: company.organization, practice_company: company)
    allow(TaxWorkHours::Configuration).to receive(:current)
      .and_return(TaxWorkHours::Configuration.new(base_url: "https://tax.example.test", secret: "x"))
    allow(TaxWorkHours::Importer).to receive(:call)
    described_class.perform_now(today: Date.new(2026, 11, 21))
    import = WorkHourImport.last
    expect(import).to have_attributes(trigger: "scheduled", range_start: Date.new(2026, 10, 1), range_end: Date.new(2026, 11, 21))
    expect(TaxWorkHours::Importer).to have_received(:call).with(import)
  end
end

RSpec.describe WorkHourImport do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }

  def reserve(**options)
    described_class.reserve!(organization: organization, trigger: "manual", range_start: Date.new(2026, 11, 1),
                             range_end: Date.new(2026, 11, 21), **options)
  end

  it "allows one queued or running import per organization, also at the database level" do
    first = reserve
    expect { reserve }.to raise_error(WorkHourImport::Busy)
    expect do
      described_class.create!(organization: organization, status: "running", range_start: first.range_start, range_end: first.range_end)
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect { described_class.reserve!(organization: create(:organization), trigger: "scheduled", range_start: first.range_start, range_end: first.range_end) }
      .not_to raise_error
  end

  it "replaces an abandoned import once its lease has run out" do
    stuck = reserve
    stuck.claim!
    travel(WorkHourImport::RUNNING_LEASE + 1.minute) do
      fresh = reserve
      expect(fresh.status).to eq("queued")
      expect(stuck.reload).to have_attributes(status: "failed", error_code: "interrupted", claim_token: nil)
    end
  end
end

RSpec.describe TaxWorkHoursImportJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:import) do
    WorkHourImport.reserve!(organization: organization, trigger: "manual", range_start: Date.new(2026, 11, 1), range_end: Date.new(2026, 11, 30))
  end

  it "waits while another worker's lease is live, then takes over an abandoned running import" do
    import.claim! # the first worker, which then dies
    expect { described_class.new.perform(import.id) }.to raise_error(TaxWorkHoursImportJob::LeaseHeld)

    allow(TaxWorkHours::Client).to receive(:new).and_return(
      instance_double(TaxWorkHours::Client, fetch: { "schema_version" => "1.0", "rows" => [], "counts" => {} })
    )
    travel(WorkHourImport::RUNNING_LEASE + 1.minute) { described_class.new.perform(import.id) }
    expect(import.reload).to have_attributes(status: "succeeded", claim_token: nil)
  end

  it "does nothing for a finished import" do
    import.update!(status: "succeeded")
    allow(TaxWorkHours::Importer).to receive(:call)
    described_class.new.perform(import.id)
    expect(TaxWorkHours::Importer).not_to have_received(:call)
  end
end
