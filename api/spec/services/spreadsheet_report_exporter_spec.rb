# frozen_string_literal: true

require "rails_helper"
require "nokogiri"
require "stringio"
require "zip"

RSpec.describe SpreadsheetReportExporter do
  it "generates valid styled workbook XML with merged cells and sheet presentation settings" do
    workbook_bytes = described_class.new(
      filename: "styled.xlsx",
      sheets: [
        {
          name: "Styled Report",
          rows: [ [ "Payroll Register", nil ], [ 1, 12.34 ] ],
          column_widths: [ 20, 14 ],
          styles: {
            header: {
              b: true,
              bg_color: "1F4E78",
              fg_color: "FFFFFF",
              alignment: { wrap_text: true }
            },
            currency: { format_code: "$#,##0.00;[Red]-$#,##0.00" }
          },
          row_style_rules: [
            { rows: 0, style: :header },
            { rows: 1, styles: [ nil, :currency ] }
          ],
          row_heights: { 0 => 24 },
          merged_cells: [ "A1:B1" ],
          show_grid_lines: false,
          zoom_scale: 80
        }
      ]
    ).generate

    Zip::File.open_buffer(StringIO.new(workbook_bytes)) do |archive|
      archive.glob("**/*.xml").each do |entry|
        expect {
          Nokogiri::XML(entry.get_input_stream.read) { |config| config.strict }
        }.not_to raise_error, "Expected #{entry.name} to contain valid XML"
      end

      sheet_xml = archive.read("xl/worksheets/sheet1.xml")
      expect(sheet_xml).to match(/<mergeCell ref=['"]A1:B1['"]/)
      expect(sheet_xml).to include('showGridLines="0"')
      expect(sheet_xml).to include('zoomScale="80"')
      expect(sheet_xml).to match(/<row[^>]+customHeight="1"[^>]+ht="24"[^>]+r="1"/)
    end
  end

  it "stores formula-like source text as inert spreadsheet values" do
    workbook_bytes = described_class.new(
      filename: "safe.xlsx",
      sheets: [ { name: "Source data", rows: [ [ "=HYPERLINK(\"https://example.test\")", "+1", "@name" ] ] } ]
    ).generate

    Zip::File.open_buffer(StringIO.new(workbook_bytes)) do |archive|
      sheet_xml = archive.read("xl/worksheets/sheet1.xml")

      expect(sheet_xml).not_to include("<f>")
      expect(sheet_xml).to include("&#39;=HYPERLINK", "&#39;+1", "&#39;@name")
    end
  end
end
