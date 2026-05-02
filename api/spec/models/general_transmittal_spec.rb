# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeneralTransmittal, type: :model do
  it "normalizes blank notes" do
    transmittal = build(:general_transmittal, notes: [ " Keep this ", "", "  " ])

    transmittal.valid?

    expect(transmittal.notes).to eq([ "Keep this" ])
  end

  it "requires at least one item when generated" do
    transmittal = build(:general_transmittal, status: "generated")

    expect(transmittal).not_to be_valid
    expect(transmittal.errors[:items]).to include("must include at least one item")
  end

  it "allows a generated transmittal with an item" do
    transmittal = build(:general_transmittal, :with_item, status: "generated")

    expect(transmittal).to be_valid
  end
end
