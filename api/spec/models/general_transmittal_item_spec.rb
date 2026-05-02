# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeneralTransmittalItem, type: :model do
  it "does not allow the same source item twice in one transmittal" do
    company = create(:company)
    transmittal = create(:general_transmittal, company: company)
    check = create(:non_employee_check, :standalone, company: company)
    create(:general_transmittal_item,
      general_transmittal: transmittal,
      source_type: "NonEmployeeCheck",
      source_id: check.id)

    duplicate = build(:general_transmittal_item,
      general_transmittal: transmittal,
      source_type: "NonEmployeeCheck",
      source_id: check.id)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:source_id]).to include("has already been added to this transmittal")
  end
end
