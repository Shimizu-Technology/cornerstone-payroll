# frozen_string_literal: true

require "zip"

# Minimal synthetic .xlsx files for preview specs. Built from raw XML so a
# spec can include real formula cells with cached values, as Excel saves them.
module SpreadsheetPreviewFixtures
  def preview_workbook(sheets, extra_entries: {})
    workbook_sheets = sheets.keys.each_with_index.map do |name, index|
      %(<sheet name="#{name}" sheetId="#{index + 1}" r:id="rId#{index + 1}"/>)
    end.join
    relationships = sheets.keys.each_index.map do |index|
      %(<Relationship Id="rId#{index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{index + 1}.xml"/>)
    end.join
    overrides = sheets.keys.each_index.map do |index|
      %(<Override PartName="/xl/worksheets/sheet#{index + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
    end.join
    entries = {
      "[Content_Types].xml" => %(<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>#{overrides}</Types>),
      "_rels/.rels" => %(<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>),
      "xl/workbook.xml" => %(<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>#{workbook_sheets}</sheets></workbook>),
      "xl/_rels/workbook.xml.rels" => %(<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{relationships}<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>),
      # Style 1: money, 2: date, 3: percent, 4: time of day.
      "xl/styles.xml" => %(<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/><numFmt numFmtId="165" formatCode="h:mm AM/PM"/></numFmts><fonts count="1"><font/></fonts><fills count="1"><fill/></fills><borders count="1"><border/></borders><cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="164" applyNumberFormat="1"/><xf numFmtId="14" applyNumberFormat="1"/><xf numFmtId="10" applyNumberFormat="1"/><xf numFmtId="165" applyNumberFormat="1"/></cellXfs></styleSheet>)
    }
    sheets.values.each_with_index do |rows, index|
      entries["xl/worksheets/sheet#{index + 1}.xml"] = %(<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{rows}</sheetData></worksheet>)
    end
    entries.merge!(extra_entries)
    buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      entries.each do |name, body|
        zip.put_next_entry(name)
        zip.write(body)
      end
    end
    buffer.string
  end

  def preview_text_cell(reference, text)
    %(<c r="#{reference}" t="inlineStr"><is><t>#{text}</t></is></c>)
  end

  def preview_grid(rows:, columns:)
    (1..rows).map do |row|
      cells = (1..columns).map { |column| preview_text_cell("#{preview_column_letter(column)}#{row}", "r#{row}c#{column}") }.join
      %(<row r="#{row}">#{cells}</row>)
    end.join
  end

  def preview_column_letter(number)
    letters = +""
    while number.positive?
      number, remainder = (number - 1).divmod(26)
      letters.prepend((65 + remainder).chr)
    end
    letters
  end
end

RSpec.configure do |config|
  config.include SpreadsheetPreviewFixtures
end
