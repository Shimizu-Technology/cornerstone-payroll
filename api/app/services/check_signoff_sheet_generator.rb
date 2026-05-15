# frozen_string_literal: true

require "caxlsx"

class CheckSignoffSheetGenerator
  attr_reader :pay_period, :company, :options

  def initialize(pay_period, options = {})
    @pay_period = pay_period
    @company = pay_period.company
    @options = options
  end

  def generate
    package = Axlsx::Package.new
    workbook = package.workbook

    workbook.add_worksheet(name: "Check Sign-Off") do |sheet|
      sheet.page_setup.set(orientation: :landscape, paper_size: 1)
      add_styles(workbook)
      build_header(sheet)
      build_table(sheet)
      build_notes(sheet)
      set_column_widths(sheet)
    end

    package.to_stream.read
  end

  def filename
    period = pay_period.start_date&.strftime("%m-%d") || "unknown"
    period_end = pay_period.end_date&.strftime("%m-%d-%Y") || "unknown"
    company_short = company.name.gsub(/[^a-zA-Z0-9]/, "")[0..15]
    "#{company_short}_CheckSignoff_PP_#{period}_#{period_end}.xlsx"
  end

  private

  def add_styles(workbook)
    @title_style = workbook.styles.add_style(
      b: true, sz: 14, alignment: { horizontal: :left }
    )
    @subtitle_style = workbook.styles.add_style(
      i: true, sz: 11, alignment: { horizontal: :left }
    )
    @header_style = workbook.styles.add_style(
      b: true, sz: 11,
      border: { style: :thin, color: "000000", edges: [:bottom] },
      alignment: { horizontal: :center }
    )
    @cell_style = workbook.styles.add_style(
      sz: 11,
      border: { style: :thin, color: "D0D0D0", edges: [:bottom] },
      alignment: { vertical: :center }
    )
    @cell_center_style = workbook.styles.add_style(
      sz: 11,
      border: { style: :thin, color: "D0D0D0", edges: [:bottom] },
      alignment: { horizontal: :center, vertical: :center }
    )
    @note_style = workbook.styles.add_style(
      sz: 10, i: true,
      alignment: { horizontal: :left, wrap_text: true }
    )
  end

  def build_header(sheet)
    sheet.add_row [company.name], style: @title_style
    period_desc = format_period_description
    sheet.add_row ["Pay Period: #{period_desc}"], style: @subtitle_style
    sheet.add_row []
    sheet.add_row(
      %w[EMPLOYEE CHECK\ NO PRINT SIGN DATE],
      style: @header_style
    )
  end

  def build_table(sheet)
    rows = employee_check_rows
    rows.each do |row|
      sheet.add_row(
        [row[:name], row[:check_number], "", "", ""],
        style: [@cell_style, @cell_center_style, @cell_style, @cell_style, @cell_style]
      )
    end
  end

  def build_notes(sheet)
    notes = resolved_notes
    return if notes.blank?

    sheet.add_row []
    sheet.add_row []
    merged_text = notes.join("\n")
    row = sheet.add_row [merged_text], style: @note_style
    sheet.merge_cells("A#{row.row_index + 1}:E#{row.row_index + 1}")
  end

  def set_column_widths(sheet)
    sheet.column_widths 40, 16, 18, 24, 18
  end

  def employee_check_rows
    if options[:custom_entries].present?
      return options[:custom_entries].map { |e|
        { name: e["name"].to_s, check_number: e["check_number"].to_s }
      }
    end

    items = pay_period.payroll_items
      .not_voided
      .joins("INNER JOIN employees ON employees.id = payroll_items.employee_id")
      .select("payroll_items.*, employees.first_name, employees.last_name")
      .order("employees.last_name ASC, employees.first_name ASC")

    items.map do |item|
      {
        name: "#{item.last_name}, #{item.first_name}",
        check_number: item.check_number.presence || ""
      }
    end
  end

  def format_period_description
    if pay_period.start_date && pay_period.end_date
      s = pay_period.start_date
      e = pay_period.end_date
      if s.month == e.month && s.year == e.year
        "#{s.strftime('%B')} #{s.day}-#{e.day}, #{e.year}"
      else
        "#{s.strftime('%B')} #{s.day} - #{e.strftime('%B')} #{e.day}, #{e.year}"
      end
    else
      pay_period.name.presence || "N/A"
    end
  end

  def resolved_notes
    custom = options[:notes]
    return custom if custom.present?

    default_notes = options[:default_notes]
    return [default_notes] if default_notes.present?

    []
  end
end
