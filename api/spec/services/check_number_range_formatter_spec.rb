# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckNumberRangeFormatter do
  it "formats contiguous numeric checks as a compact range" do
    expect(described_class.format(%w[1001 1002 1003])).to eq("1001-1003")
  end

  it "formats gaps without implying missing checks were issued" do
    expect(described_class.format(%w[1001 1002 1005 1010 1011 1012])).to eq("1001-1002, 1005, 1010-1012")
  end

  it "keeps non-numeric check numbers as exact values" do
    expect(described_class.format(["1002", "MANUAL-A", "1001"])).to eq("1001-1002, MANUAL-A")
  end
end
