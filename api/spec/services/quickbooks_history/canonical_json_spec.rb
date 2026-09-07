# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::CanonicalJson do
  it "normalizes key order, money, dates, and times deterministically" do
    instant = Time.zone.parse("2026-09-07 10:15:30")
    first = {
      amount: BigDecimal("0.00"),
      count: 3,
      ratio: 1.25,
      optional: nil,
      nested: { b: Date.new(2026, 9, 7), a: instant },
      rows: [ { value: BigDecimal("12.30") } ]
    }
    second = {
      "rows" => [ { "value" => BigDecimal("12.30") } ],
      "nested" => { "a" => instant, "b" => Date.new(2026, 9, 7) },
      "optional" => nil,
      "ratio" => 1.25,
      "count" => 3,
      "amount" => BigDecimal("-0.00")
    }

    expect(described_class.normalize(first)).to eq(described_class.normalize(second))
    expect(described_class.normalize(first).keys).to eq(%w[amount count nested optional ratio rows])
    expect(described_class.normalize(first).fetch("nested").keys).to eq(%w[a b])
    expect(described_class.normalize(first)).to eq(
      "amount" => "0.0",
      "count" => 3,
      "nested" => { "a" => instant.iso8601, "b" => "2026-09-07" },
      "optional" => nil,
      "ratio" => 1.25,
      "rows" => [ { "value" => "12.3" } ]
    )
    expect(Digest::SHA256.hexdigest(JSON.generate(described_class.normalize(first))))
      .to eq(Digest::SHA256.hexdigest(JSON.generate(described_class.normalize(second))))
  end

  it "rejects keys that collide after stringification" do
    expect { described_class.normalize({ value: 1, "value" => 2 }) }
      .to raise_error(ArgumentError, /keys that collide/)
  end
end
