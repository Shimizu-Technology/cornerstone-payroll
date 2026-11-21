# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxWorkHours::Importer do
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
    WorkHourImport.create!(organization: organization, range_start: first, range_end: last)
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
  it "does nothing while Tax isn't connected" do
    allow(TaxWorkHours::Configuration).to receive(:current).and_return(TaxWorkHours::Configuration.new(base_url: nil, secret: nil))
    expect { described_class.perform_now }.not_to change(WorkHourImport, :count)
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
