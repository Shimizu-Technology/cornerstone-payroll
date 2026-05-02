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

  it "rejects duplicate source items before nested items are saved" do
    check = create(:non_employee_check, :standalone)
    transmittal = build(:general_transmittal)
    2.times do |index|
      transmittal.items << build(:general_transmittal_item,
        general_transmittal: transmittal,
        source_type: "NonEmployeeCheck",
        source_id: check.id,
        position: index)
    end

    expect(transmittal).not_to be_valid
    expect(transmittal.errors[:items].join(" ")).to include("already been added")
  end
end
