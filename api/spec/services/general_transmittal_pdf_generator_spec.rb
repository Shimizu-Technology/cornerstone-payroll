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
end
