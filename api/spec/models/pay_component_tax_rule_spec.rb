# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayComponentTaxRule do
  let(:company) { create(:company) }

  def attributes
    {
      company: company,
      component_key: "bonus",
      display_name: "Bonus",
      component_kind: "earning",
      fit_treatment: "taxable",
      social_security_treatment: "taxable",
      medicare_treatment: "taxable",
      additional_medicare_treatment: "taxable",
      swica_treatment: "included",
      retirement_treatment: "included",
      reimbursement_treatment: "not_applicable",
      effective_from: Date.new(2026, 1, 1),
      source_name: "Approved company rule",
      version: "1"
    }
  end

  it "prevents overlapping active effective ranges for a component" do
    described_class.create!(**attributes, effective_to: Date.new(2026, 12, 31))
    overlapping = described_class.new(**attributes.merge(
      effective_from: Date.new(2026, 6, 1),
      version: "2"
    ))

    expect(overlapping).not_to be_valid
    expect(overlapping.errors[:effective_from]).to include(/overlaps/)
  end

  it "allows a later non-overlapping version" do
    described_class.create!(**attributes, effective_to: Date.new(2026, 12, 31))
    later = described_class.new(**attributes.merge(
      effective_from: Date.new(2027, 1, 1),
      version: "2"
    ))

    expect(later).to be_valid
  end
end
