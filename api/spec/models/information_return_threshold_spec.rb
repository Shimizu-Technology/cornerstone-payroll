# frozen_string_literal: true

require "rails_helper"

RSpec.describe InformationReturnThreshold, type: :model do
  it "selects the threshold by form and tax year" do
    rule = described_class.find_or_initialize_by(form_type: "1099_nec", tax_year: 2026)
    rule.update!(threshold_amount: 2_000, source_url: "https://www.irs.gov/instructions/i1099mec", effective_on: Date.new(2026, 1, 1))

    expect(described_class.for!(form_type: :"1099_nec", tax_year: 2026)).to eq(rule)
  end

  it "fails closed when a year has no configured threshold" do
    expect {
      described_class.for!(form_type: :"1099_nec", tax_year: 2099)
    }.to raise_error(ArgumentError, /No 1099_nec reporting threshold/)
  end
end
