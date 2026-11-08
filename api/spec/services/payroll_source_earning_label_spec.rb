require "rails_helper"

RSpec.describe PayrollSourceEarningLabel do
  let(:label) { "Admin Duties · AIRE carryover from Sep 15, 2026 · $10.00/hr" }
  let(:bucket) { { "label" => label, "source_lines" => [ { "source_kind" => "carryover", "original_work_date" => "2026-09-15" } ] } }
  let(:item) { instance_double(PayrollItem, wage_rate_hours: [ bucket ], import_source: "time_tracking:aire_services:1:BATCH") }

  it "keeps the original date and OT ahead of optional category text without changing saved labels" do
    saved = Marshal.dump(bucket)
    expect(described_class.new(item).call("#{label} OT", compact: true)).to eq("Prior-period OT\n09/15/26\nAdmin Duties")
    expect(described_class.new(item).call(label)).to eq("Prior-period hours worked Sep 15, 2026\nAdmin Duties")
    expect(Marshal.dump(bucket)).to eq(saved)
  end

  it "preserves date gaps and year boundaries" do
    bucket["source_lines"] = %w[2025-12-31 2026-01-01 2026-01-03].map { |date| { "source_kind" => "carryover", "original_work_date" => date } }
    expect(described_class.new(item).call(label, compact: true)).to include("12/31/25-01/01/26, 01/03/26")
  end

  it "does not add a prior paycheck's intervening work dates to current paid hours" do
    bucket["source_lines"] = %w[2026-09-01 2026-09-15].map { |date| { "source_kind" => "carryover", "original_work_date" => date } }
    historical_bucket = bucket.deep_dup
    historical_bucket["source_lines"] << { "source_kind" => "carryover", "original_work_date" => "2026-09-08" }
    historical = instance_double(PayrollItem, wage_rate_hours: [ historical_bucket ])
    formatted = described_class.new(item, source_items: [ historical ]).call(label, compact: true)
    expect(formatted).to include("09/01/26", "09/15/26")
    expect(formatted).not_to include("09/08/26")
  end

  it "keeps a signed correction distinct from prior-period pay" do
    bucket["source_lines"].first["source_kind"] = "correction"
    expect(described_class.new(item).call("#{label} OT", compact: true)).to start_with("Correction OT\n09/15/26")
  end

  it "never borrows imported REG/OT dates for preserved holiday or PTO" do
    %w[Holiday PTO].each do |kind|
      expect(described_class.new(item).call("#{label} #{kind}", compact: true)).to eq("#{kind}\nAdmin Duties")
      expect(described_class.new(item).call("#{label} #{kind}")).to eq("Admin Duties #{kind}")
    end
  end

  it "retains dates, OT and reversal meaning for negative calculator labels" do
    bucket["source_lines"].first["source_kind"] = "correction"
    expect(described_class.new(item).call("#{label} correction reversal", compact: true)).to eq("Correction reversal\n09/15/26\nAdmin Duties")
    expect(described_class.new(item).call("#{label} OT correction reversal", compact: true)).to eq("Correction OT reversal\n09/15/26\nAdmin Duties")
    expect(described_class.new(item).call("#{label} OT correction reversal")).to include("Correction reversal hours worked Sep 15, 2026", "Admin Duties OT reversal")
  end

  it "retains each source kind's dates on a mixed-kind YTD-only financial row" do
    allow(item).to receive_messages(wage_rate_hours: [], time_tracking_entry_allocations: [])
    correction = { "label" => label, "source_lines" => [ { "source_kind" => "correction", "original_work_date" => "2026-09-16" } ] }
    historical = [ bucket, correction ].map { |entry| instance_double(PayrollItem, wage_rate_hours: [ entry ]) }
    formatted = described_class.new(item, source_items: historical).call("#{label} OT", compact: true)
    expect(formatted).to include("Prior-period OT\n09/15/26", "Correction OT\n09/16/26")
    full = described_class.new(item, source_items: historical).call(label)
    expect(full).to include("Prior-period hours worked Sep 15, 2026", "Correction hours worked Sep 16, 2026")
  end

  it "loads missing historical allocation evidence in one query" do
    items = Array.new(6) { build_stubbed(:payroll_item, import_source: "time_tracking:aire_services:1:BATCH", wage_rate_hours: []) }
    queries = []
    listener = ->(*args) { queries << args.last[:sql] if args.last[:sql].match?(/SELECT.*FROM "time_tracking_entry_allocations"/m) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      expect(described_class.new(items.first, source_items: items.drop(1)).call(label)).to be_nil
    end
    expect(queries.size).to eq(1)
  end

  it "uses immutable allocation evidence for older saved items without wage buckets" do
    allow(item).to receive(:wage_rate_hours).and_return([])
    allow(item).to receive(:time_tracking_entry_allocations).and_return([ double(earning_snapshot: bucket) ])
    expect(described_class.new(item).call(label)).to include("Sep 15, 2026")
  end

  it "does not invent dates or classify unrelated earnings" do
    bucket["source_lines"].first["original_work_date"] = "unknown"
    expect(described_class.new(item).call(label)).to be_nil
    expect(described_class.new(item).call("Unrelated Admin Duties")).to be_nil
  end
end
