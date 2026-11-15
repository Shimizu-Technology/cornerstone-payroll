# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpreadsheetPreview do
  def preview(bytes, filename = "changes.xlsx")
    described_class.new(bytes: bytes, filename: filename).call
  end

  it "returns readable computed values, never formulas" do
    rows = <<~XML
      <row r="1">#{preview_text_cell('A1', 'Employee')}#{preview_text_cell('B1', 'Tips')}#{preview_text_cell('C1', 'Date')}#{preview_text_cell('D1', 'Share')}#{preview_text_cell('E1', 'Clock in')}#{preview_text_cell('F1', 'Hours')}#{preview_text_cell('G1', 'Paid')}</row>
      <row r="2">#{preview_text_cell('A2', 'Ava Cruz')}<c r="B2" s="1"><v>1234.5</v></c><c r="C2" s="2"><v>46328</v></c><c r="D2" s="3"><v>0.075</v></c><c r="E2" s="4"><v>0.375</v></c><c r="F2"><v>12.5</v></c><c r="G2" t="b"><v>1</v></c></row>
      <row r="4">#{preview_text_cell('A4', 'Total')}<c r="B4" s="1"><f>SUM(B2:B3)</f><v>1234.5</v></c><c r="F4"><f>SUM(F2:F3)</f></c></row>
    XML

    result = preview(preview_workbook({ "TIPS" => rows }))

    sheet = result.fetch(:sheets).sole
    expect(sheet).to include(name: "TIPS", columns: 7, truncated_rows: false, truncated_columns: false)
    expect(sheet[:rows].map { |row| row[:number] }).to eq([ 1, 2, 4 ])
    expect(sheet[:rows][1][:cells]).to eq([ "Ava Cruz", "$1,234.50", "11/02/2026", "7.50%", "9:00 AM", "12.5", "TRUE" ])
    expect(sheet[:rows][2][:cells].first(2)).to eq([ "Total", "$1,234.50" ])
    expect(sheet[:rows][2][:cells].join).not_to include("SUM")
    expect(result).to include(sheet_count: 1, truncated_sheets: false)
  end

  it "caps rows, columns and sheets and says so" do
    big = preview_grid(rows: SpreadsheetPreview::MAX_ROWS + 3, columns: SpreadsheetPreview::MAX_COLUMNS + 2)
    sheets = { "Big" => big }
    (2..SpreadsheetPreview::MAX_SHEETS + 1).each { |index| sheets["Sheet #{index}"] = preview_grid(rows: 1, columns: 1) }

    result = preview(preview_workbook(sheets))

    expect(result[:sheet_count]).to eq(SpreadsheetPreview::MAX_SHEETS + 1)
    expect(result[:sheets].length).to eq(SpreadsheetPreview::MAX_SHEETS)
    expect(result[:truncated_sheets]).to be(true)
    first = result[:sheets].first
    expect(first[:rows].length).to eq(SpreadsheetPreview::MAX_ROWS)
    expect(first[:columns]).to eq(SpreadsheetPreview::MAX_COLUMNS)
    expect(first[:rows].first[:cells].length).to eq(SpreadsheetPreview::MAX_COLUMNS)
    expect(first).to include(truncated_rows: true, truncated_columns: true)
  end

  it "places a far-right cell without padding to it, and shows elapsed hours as hours" do
    rows = %(<row r="1">#{preview_text_cell('A1', 'Hours')}<c r="B1" s="5"><v>1.5</v></c><c r="C1" s="5"><v>0.25</v></c>#{preview_text_cell('ZZZZ1', 'far')}</row>)

    expect(Roo::Excelx::Cell::Empty).not_to receive(:new)
    sheet = preview(preview_workbook({ "A" => rows }))[:sheets].sole

    expect(sheet[:rows].sole[:cells]).to eq([ "Hours", "36:00", "6:00" ])
    expect(sheet).to include(columns: 3, truncated_columns: true)
  end

  it "reads CSV as one sheet" do
    result = preview("﻿name,hours\nAva Cruz,40\n\n\"Reyes, Bo\",12.5\n", "hours.csv")

    sheet = result[:sheets].sole
    expect(sheet[:name]).to eq("hours")
    expect(sheet[:rows]).to eq([
      { number: 1, cells: %w[name hours] },
      { number: 2, cells: [ "Ava Cruz", "40" ] },
      { number: 4, cells: [ "Reyes, Bo", "12.5" ] }
    ])
  end

  it "explains corrupt, macro-enabled and unsupported files instead of failing" do
    expect { preview("PK\x03\x04not really a zip") }.to raise_error(described_class::Error, /could not be read/)
    expect { preview("plain text pretending", "changes.xlsx") }.to raise_error(described_class::Error, /could not be read/)
    expect { preview(preview_workbook({ "A" => "" }, extra_entries: { "xl/vbaProject.bin" => "synthetic" })) }
      .to raise_error(described_class::Error, /contains macros/)
    expect { preview(preview_workbook({ "A" => "" }), "changes.xlsm") }.to raise_error(described_class::Error, /Macro-enabled/)
    expect { preview("\xD0\xCF\x11\xE0".b, "old.xls") }.to raise_error(described_class::Error, /Older Excel files/)
    expect { preview("\"unterminated\n", "bad.csv") }.to raise_error(described_class::Error, /CSV file could not be read/)
  end

  it "refuses archives that expand past the limit before roo unpacks them" do
    stub_const("SpreadsheetPreview::MAX_EXPANDED_BYTES", 2.kilobytes)
    bytes = preview_workbook({ "A" => "" }, extra_entries: { "xl/media/padding.bin" => "x" * 4.kilobytes })

    expect { preview(bytes) }.to raise_error(described_class::Error, /too large to preview/)
  end
end
