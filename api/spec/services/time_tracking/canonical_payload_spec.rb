# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::CanonicalPayload do
  it "produces the same checksum regardless of object key order" do
    first = { beta: [ { z: 1, a: 2 } ], alpha: { two: 2, one: 1 } }
    second = { "alpha" => { "one" => 1, "two" => 2 }, "beta" => [ { "a" => 2, "z" => 1 } ] }

    expect(described_class.checksum(first)).to eq(described_class.checksum(second))
  end

  it "preserves array order" do
    expect(described_class.checksum(rows: [ 1, 2 ])).not_to eq(described_class.checksum(rows: [ 2, 1 ]))
  end
end
