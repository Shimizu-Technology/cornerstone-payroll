# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrinterProfile do
  it "enforces one revision number per source profile at the database boundary" do
    organization = create(:organization)
    source = PrinterProfile.create!(
      organization: organization,
      name: "Source Printer",
      check_stock_type: "top_check",
      check_offset_x: 0,
      check_offset_y: 0
    )
    PrinterProfile.create!(
      organization: organization,
      source_profile: source,
      revision_number: 2,
      name: "Source Printer copy",
      check_stock_type: "top_check",
      check_offset_x: 0,
      check_offset_y: 0
    )
    duplicate = PrinterProfile.new(
      organization: organization,
      source_profile: source,
      revision_number: 2,
      name: "Source Printer duplicate revision",
      check_stock_type: "top_check",
      check_offset_x: 0,
      check_offset_y: 0
    )

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
