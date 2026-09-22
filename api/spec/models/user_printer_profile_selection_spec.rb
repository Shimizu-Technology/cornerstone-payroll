# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserPrinterProfileSelection, type: :model do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization, check_stock_type: "top_check") }
  let(:user) { create(:user, company: company, organization: organization) }

  it "allows one personal selection per organization and stock type" do
    first = PrinterProfile.create!(organization: organization, name: "Printer A",
      check_stock_type: "top_check", check_offset_x: 0, check_offset_y: 0)
    second = PrinterProfile.create!(organization: organization, name: "Printer B",
      check_stock_type: "top_check", check_offset_x: 0, check_offset_y: 0)
    described_class.create!(user: user, organization: organization,
      printer_profile: first, check_stock_type: "top_check")

    duplicate = described_class.new(user: user, organization: organization,
      printer_profile: second, check_stock_type: "top_check")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:check_stock_type]).to include("has already been taken")
  end

  it "rejects cross-organization and mismatched-stock profiles" do
    other_organization = create(:organization)
    foreign_profile = PrinterProfile.create!(organization: other_organization, name: "Foreign Printer",
      check_stock_type: "bottom_check", check_offset_x: 0, check_offset_y: 0)
    selection = described_class.new(user: user, organization: organization,
      printer_profile: foreign_profile, check_stock_type: "top_check")

    expect(selection).not_to be_valid
    expect(selection.errors[:printer_profile]).to include("must belong to the selected organization")
    expect(selection.errors[:printer_profile]).to include("must match the selected check stock")
  end
end
