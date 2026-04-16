# frozen_string_literal: true

require "prawn"
require "prawn/table"

class CheckSignoffPdfGenerator
  HEADER_COLOR  = "2B4090"
  BORDER_COLOR  = "CCCCCC"
  HEADER_BG     = "F0F4FA"
  STRIPE_COLOR  = "F9FAFB"

  attr_reader :pay_period, :company, :options

  def initialize(pay_period, options = {})
    @pay_period = pay_period
    @company = pay_period.company
    @options = options
  end

  def generate
    pdf = Prawn::Document.new(
      page_size: "LETTER",
      page_layout: :portrait,
      margin: [36, 40, 36, 40]
    )
    render_document(pdf)
    pdf.render
  end

  def filename
    period = pay_period.start_date&.strftime("%m-%d") || "unknown"
    period_end = pay_period.end_date&.strftime("%m-%d-%Y") || "unknown"
    company_short = company.name.gsub(/[^a-zA-Z0-9]/, "")[0..15]
    "#{company_short}_CheckSignoff_PP_#{period}_#{period_end}.pdf"
  end

  private

  def render_document(pdf)
    render_header(pdf)
    render_table(pdf)
    render_notes(pdf)
  end

  def render_header(pdf)
    pdf.font_size(14) { pdf.text company.name, style: :bold, color: HEADER_COLOR }
    pdf.move_down 4
    pdf.font_size(10) do
      pdf.text "Check Sign-Off Sheet", style: :bold
      pdf.move_down 2
      pdf.text "Pay Period: #{format_period_description}", color: "444444"
    end
    pdf.move_down 16
  end

  def render_table(pdf)
    rows = employee_check_rows

    col_widths = compute_column_widths(pdf)

    header = [
      { content: "#", font_style: :bold },
      { content: "EMPLOYEE", font_style: :bold },
      { content: "CHECK NO.", font_style: :bold },
      { content: "PRINT", font_style: :bold },
      { content: "SIGN", font_style: :bold },
      { content: "DATE", font_style: :bold },
    ]

    table_data = [header]

    rows.each_with_index do |row, i|
      table_data << [
        { content: (i + 1).to_s },
        { content: row[:name] },
        { content: row[:check_number].to_s },
        { content: "" },
        { content: "" },
        { content: "" },
      ]
    end

    pdf.table(table_data, column_widths: col_widths, cell_style: {
      size: 9,
      padding: [6, 8, 6, 8],
      border_width: 0.5,
      border_color: BORDER_COLOR,
      inline_format: true,
    }) do |t|
      t.row(0).background_color = HEADER_BG
      t.row(0).text_color = "333333"
      t.row(0).size = 8

      t.columns(0).align = :center
      t.columns(2).align = :center
      t.columns(3).align = :center
      t.columns(4).align = :center
      t.columns(5).align = :center

      rows.each_with_index do |_, i|
        t.row(i + 1).background_color = STRIPE_COLOR if i.odd?
      end
    end
  end

  def render_notes(pdf)
    notes = resolved_notes
    return if notes.blank?

    pdf.move_down 20
    pdf.font_size(9) do
      pdf.text "Notes:", style: :bold, color: "444444"
      pdf.move_down 4
      notes.each do |note|
        pdf.text "• #{note}", color: "555555"
        pdf.move_down 2
      end
    end
  end

  def compute_column_widths(pdf)
    total = pdf.bounds.width
    [30, total - 330, 60, 70, 90, 80]
  end

  def employee_check_rows
    if options[:custom_entries].present?
      return options[:custom_entries].map { |e|
        { name: e["name"].to_s, check_number: e["check_number"].to_s }
      }
    end

    items = pay_period.payroll_items
      .where(voided: false)
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
