# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::SpreadsheetReader do
  it "closes an xlsx workbook after materializing its rows" do
    sheet = instance_double(Roo::Excelx, first_row: 1, last_row: 1)
    allow(sheet).to receive(:row).with(1).and_return([ "value" ])
    workbook = instance_double(Roo::Excelx, sheet: sheet)
    allow(workbook).to receive(:close)
    allow(Roo::Spreadsheet).to receive(:open).and_return(workbook)

    expect(described_class.read(path: "/tmp/example.xlsx", extension: ".xlsx")).to eq([ [ "value" ] ])
    expect(workbook).to have_received(:close)
  end

  it "closes an xlsx workbook when row materialization fails" do
    sheet = instance_double(Roo::Excelx, first_row: 1, last_row: 1)
    allow(sheet).to receive(:row).and_raise(StandardError, "invalid row")
    workbook = instance_double(Roo::Excelx, sheet: sheet)
    allow(workbook).to receive(:close)
    allow(Roo::Spreadsheet).to receive(:open).and_return(workbook)

    expect do
      described_class.read(path: "/tmp/example.xlsx", extension: ".xlsx")
    end.to raise_error(StandardError, "invalid row")
    expect(workbook).to have_received(:close)
  end
end
