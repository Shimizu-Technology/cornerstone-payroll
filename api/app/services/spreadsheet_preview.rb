# frozen_string_literal: true

require "csv"
require "tmpdir"
require "zip"

# Read-only sheet tables for previewing a stored workbook or CSV in the browser.
# Only cached cell values are returned (never formulas), macros are never run,
# and every sheet is capped so a large or hostile file cannot flood a response.
class SpreadsheetPreview
  MAX_SHEETS = 10
  MAX_ROWS = 500
  MAX_COLUMNS = 50
  MAX_CELL_CHARACTERS = 500
  MAX_ZIP_ENTRIES = 1_000
  MAX_EXPANDED_BYTES = 100.megabytes
  SUPPORTED_EXTENSIONS = %w[xlsx csv].freeze
  # Spreadsheet types that get a sheet preview or a clear "can't preview" reason.
  SPREADSHEET_EXTENSIONS = %w[xlsx xlsm xls csv].freeze
  UNREADABLE_MESSAGE = "This spreadsheet could not be read. It may be damaged or saved in a format the preview " \
                       "does not support. Download the file to open it in Excel."

  class Error < StandardError; end

  def self.supported?(filename)
    SUPPORTED_EXTENSIONS.include?(extension_for(filename))
  end

  def self.spreadsheet?(filename)
    SPREADSHEET_EXTENSIONS.include?(extension_for(filename))
  end

  def self.extension_for(filename)
    File.extname(filename.to_s).delete(".").downcase
  end

  def initialize(bytes:, filename:)
    @bytes = bytes.to_s.b
    @filename = filename.to_s
  end

  def call
    case self.class.extension_for(@filename)
    when "xlsx" then workbook_preview
    when "csv" then csv_preview
    when "xlsm" then raise Error, "Macro-enabled workbooks (.xlsm) are not previewed. Download the file to open it in Excel."
    when "xls" then raise Error, "Older Excel files (.xls) can't be previewed here yet. Download the file to open it in Excel."
    else raise Error, "This file type can't be previewed as a spreadsheet. Download the file to open it."
    end
  end

  private

  def workbook_preview
    raise Error, UNREADABLE_MESSAGE unless @bytes.start_with?("PK\x03\x04".b)

    check_zip_container!
    Dir.mktmpdir("spreadsheet-preview") do |dir|
      path = File.join(dir, "workbook.xlsx")
      File.binwrite(path, @bytes)
      workbook = Roo::Excelx.new(path, tmpdir_root: dir, file_warning: :ignore)
      begin
        names = workbook.sheets
        sheets = names.first(MAX_SHEETS).map { |name| workbook_sheet(workbook, name) }
        result(sheets, sheet_count: names.length)
      ensure
        workbook.close
      end
    end
  rescue Error
    raise
  rescue StandardError => e
    Rails.logger.info("Spreadsheet preview failed for #{@filename.inspect}: #{e.class}: #{e.message}")
    raise Error, UNREADABLE_MESSAGE
  end

  # Roo unpacks the archive to disk, so refuse archive bombs and macro parts
  # before it runs. rubyzip also checks real entry sizes while extracting.
  def check_zip_container!
    Zip::File.open_buffer(StringIO.new(@bytes)) do |zip|
      entries = zip.entries
      raise Error, "This workbook contains too many parts to preview. Download the file to open it in Excel." if entries.size > MAX_ZIP_ENTRIES
      if entries.sum(&:size) > MAX_EXPANDED_BYTES
        raise Error, "This workbook is too large to preview. Download the file to open it in Excel."
      end
      if entries.any? { |entry| entry.name.match?(/vba|macro|activex/i) }
        raise Error, "This workbook contains macros, so it is not previewed. Download the file to open it in Excel."
      end
    end
  end

  # Cells are placed by their own coordinates into a fixed-width row, so a
  # single far-right cell (say ZZZZ1) can't make roo pad a huge array.
  def workbook_sheet(workbook, name)
    rows = []
    truncated_rows = false
    truncated_columns = false
    workbook.each_row_streaming(sheet: name) do |cells|
      values = Array.new(MAX_COLUMNS)
      row_number = nil
      cells.each do |cell|
        text = cell_text(cell)
        next if text.blank?

        column = cell.coordinate.column
        row_number ||= cell.coordinate.row
        if column > MAX_COLUMNS
          truncated_columns = true
        else
          values[column - 1] = text
        end
      end
      next if values.all?(&:blank?)

      if rows.length >= MAX_ROWS
        truncated_rows = true
        break
      end
      rows << { number: row_number, cells: values }
    end
    sheet_result(name, rows, truncated_rows:, truncated_columns:)
  end

  def csv_preview
    text = decode_text(@bytes)
    rows = []
    truncated_rows = false
    truncated_columns = false
    line = 0
    CSV.new(text, liberal_parsing: true, field_size_limit: 1.megabyte).each do |fields|
      line += 1
      values = fields.map { |value| clip(value.to_s) }
      next if values.all?(&:blank?)

      if rows.length >= MAX_ROWS
        truncated_rows = true
        break
      end
      truncated_columns ||= values.drop(MAX_COLUMNS).any?(&:present?)
      rows << { number: line, cells: values.first(MAX_COLUMNS) }
    end
    result([ sheet_result(File.basename(@filename, ".*").presence || "CSV", rows, truncated_rows:, truncated_columns:) ], sheet_count: 1)
  rescue CSV::MalformedCSVError, EncodingError
    raise Error, "This CSV file could not be read. Download the file to open it in a spreadsheet app."
  end

  def sheet_result(name, rows, truncated_rows:, truncated_columns:)
    width = rows.map { |row| row[:cells].rindex(&:present?).to_i + 1 }.max || 0
    {
      name: name.to_s,
      columns: width,
      rows: rows.map { |row| cells = row[:cells].first(width); { number: row[:number], cells: cells.fill(nil, cells.length...width) } },
      truncated_rows: truncated_rows,
      truncated_columns: truncated_columns
    }
  end

  def result(sheets, sheet_count:)
    {
      sheets: sheets,
      sheet_count: sheet_count,
      truncated_sheets: sheet_count > sheets.length,
      limits: { sheets: MAX_SHEETS, rows: MAX_ROWS, columns: MAX_COLUMNS }
    }
  end

  def cell_text(cell)
    return nil if cell.nil? || cell.empty?

    return clip(format_elapsed(cell.cell_value.to_s.to_f)) if elapsed_format?(cell)

    text = case cell
    when Roo::Excelx::Cell::Time then format_time_of_day(cell.value)
    when Roo::Excelx::Cell::DateTime then format_date_cell(cell) # includes Date
    when Roo::Excelx::Cell::Boolean then cell.value ? "TRUE" : "FALSE"
    when Roo::Excelx::Cell::Number then format_number(cell.value, cell.format.to_s)
    else cell.value.to_s
    end
    clip(text)
  end

  # Durations like [h]:mm count total hours past 24, so read them from the
  # stored serial (days) instead of as a date or a time of day.
  def elapsed_format?(cell)
    cell.respond_to?(:format) && cell.format.to_s.match?(/\[(h+|m+|s+)\]/i) && cell.cell_value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
  end

  def format_elapsed(days)
    minutes = (days.abs * 1440).round
    format("%s%d:%02d", days.negative? && minutes.positive? ? "-" : "", minutes / 60, minutes % 60)
  end

  # roo files some time-only formats ("h:mm AM/PM") as dates, so read the
  # time of day from the stored serial value instead of the parsed date.
  def format_date_cell(cell)
    return cell.value.to_s unless cell.value.respond_to?(:strftime)

    serial = cell.cell_value.to_s.to_f
    seconds = ((serial % 1) * 86_400).round
    show_time = cell.format.to_s.match?(/h/i) || !seconds.zero?
    return format_time_of_day(seconds) if show_time && serial.abs < 1

    date = cell.value.strftime("%m/%d/%Y")
    show_time ? "#{date} #{format_time_of_day(seconds)}" : date
  end

  def format_time_of_day(seconds)
    seconds = seconds.to_i
    hour = (seconds / 3600) % 24
    minute = (seconds % 3600) / 60
    format("%d:%02d %s", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
  end

  # Readable numbers that follow the cell's own decimals, grouping, currency
  # and percent hints. "General" keeps the exact stored value.
  def format_number(value, number_format)
    return value.to_s unless value.is_a?(Numeric)

    raw_section = number_format.split(";").first.to_s
    section = raw_section.gsub(/"[^"]*"|\[[^\]]*\]|\\./, "")
    percent = section.include?("%")
    value *= 100 if percent
    decimals = section[/\.(0+)/, 1]&.length
    text = if decimals
      grouped(format("%.#{decimals}f", value.abs), section.include?(","))
    else
      plain = value.abs.round(10)
      plain = plain.to_i if plain == plain.to_i
      grouped(plain.to_s, section.include?(","))
    end
    text = "$#{text}" if raw_section.include?("$")
    text = "#{text}%" if percent
    value.negative? && text.match?(/[1-9]/) ? "-#{text}" : text
  end

  def grouped(number_text, group)
    return number_text unless group

    whole, fraction = number_text.split(".", 2)
    whole = whole.reverse.scan(/\d{1,3}/).join(",").reverse
    fraction ? "#{whole}.#{fraction}" : whole
  end

  def clip(text)
    text = text.to_s.strip
    return nil if text.empty?

    text.length > MAX_CELL_CHARACTERS ? "#{text[0, MAX_CELL_CHARACTERS]}…" : text
  end

  def decode_text(bytes)
    encoding = if bytes.start_with?("\xFF\xFE".b)
      Encoding::UTF_16LE
    elsif bytes.start_with?("\xFE\xFF".b)
      Encoding::UTF_16BE
    elsif bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      Encoding::UTF_8
    else
      Encoding::Windows_1252
    end
    bytes.dup.force_encoding(encoding).encode(Encoding::UTF_8).delete_prefix("﻿")
  end
end
