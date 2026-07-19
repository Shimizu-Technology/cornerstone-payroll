# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe GeneralTransmittalPdfGenerator do
  let(:transmittal) { create(:general_transmittal, :with_item, title: "Q2 Returns") }

  subject(:generator) { described_class.new(transmittal) }

  it "returns a valid PDF" do
    pdf = generator.generate

    expect(pdf).to start_with("%PDF")
    expect(pdf.bytesize).to be > 1_000
  end

  it "renders transmittal item details" do
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

    expect(text).to include("Q2 Returns")
    expect(text).to include("Quarterly return check")
    expect(text).to include("Guam DRT")
    expect(text).to include("5001")
  end

  it "excludes unchecked rows and labels calculated obligations as calculations, not payments" do
    transmittal.items.first.update!(included: false)
    transmittal.items.create!(
      item_type: "tax_obligation",
      title: "Guam income tax withholding",
      amount: 75.00,
      position: 1,
      included: true
    )

    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

    expect(text).not_to include("Quarterly return check")
    expect(text).to include("Guam income tax withholding")
    expect(text).to include("Calculated obligation")
    expect(text).to include("not payment evidence")
  end
end
