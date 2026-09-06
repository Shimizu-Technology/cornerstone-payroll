# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::NameNormalizer do
  it "normalizes Latin names to their ASCII identity" do
    expect(described_class.call("  *García, Ana-María ")).to eq("garcia ana maria")
  end

  it "preserves a stable identity for names written entirely in a non-Latin script" do
    expect(described_class.call("山田 太郎")).to eq("山田 太郎")
  end

  it "uses the same normalization path for QuickBooks and live employees" do
    employee = build(:employee, last_name: "山田", first_name: "太郎", middle_name: nil)

    expect(described_class.employee(employee)).to eq(described_class.call("山田 太郎"))
  end
end
