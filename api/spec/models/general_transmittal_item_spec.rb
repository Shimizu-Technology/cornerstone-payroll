# frozen_string_literal: true

require "rails_helper"

RSpec.describe GeneralTransmittalItem, type: :model do
  it "sets the company on a check snapshot before the item is attached" do
    check = create(:non_employee_check, :standalone)

    expect(described_class.from_non_employee_check(check, position: 0).company_id).to eq(check.company_id)
  end

  it "fills a missing company from the parent when a legacy item is updated" do
    item = create(:general_transmittal_item)
    item.update_column(:company_id, nil)

    item.update!(title: "Reviewed legacy line")

    expect(item.reload.company_id).to eq(item.general_transmittal.company_id)
  end

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
