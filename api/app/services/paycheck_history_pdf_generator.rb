# frozen_string_literal: true

require "prawn"
require "prawn/table"

# QuickBooks-style Paycheck History with Cornerstone check/status detail.
class PaycheckHistoryPdfGenerator
  QB_BORDER = "B7BDC7"
  QB_HEADER_BG = "F2F2F2"
  QB_TOTAL_BG = "F7F7F7"
  TEXT = "3B3B3B"
  MUTED = "666666"

  attr_reader :pay_period, :company, :data

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
    @data = QuickbooksPayrollReportData.new(pay_period)
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [ 36, 36, 46, 36 ])
    render_header(pdf)

    rows = data.paycheck_history_rows(include_voided: true)
    if rows.empty?
      pdf.text "No paychecks found.", style: :italic, color: MUTED
    else
      render_history_table(pdf, rows)
      render_detail_table(pdf, rows)
    end

    render_footer(pdf)
    pdf.render
  end

  def filename
    "paycheck_history_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_header(pdf)
    pdf.fill_color TEXT
    pdf.font_size(13) { pdf.text company.name, align: :center }
    pdf.move_down 12
    pdf.font_size(20) { pdf.text "Paycheck history report", align: :center }
    pdf.move_down 12
    pdf.font_size(14) { pdf.text "Paychecks #{data.qb_date_range_label.sub(/\AFrom/, 'from')}", align: :center }
    pdf.move_down 24
  end

  def render_history_table(pdf, rows)
    table_rows = [ [ "Pay date", "Name", "Total pay", "Net pay", "Pay method", "Check #", "Status" ] ]
    rows.each do |row|
      table_rows << [ date(row[:pay_date]), row[:employee_name], money(row[:total_pay]), money(row[:net_pay]), row[:pay_method], row[:check_number].presence || "—", row[:status].to_s.titleize ]
    end
    table_rows << [ "Total", "#{rows.count} paychecks", money(rows.sum { |row| row[:total_pay].to_f }), money(rows.sum { |row| row[:net_pay].to_f }), "", "", "" ]

    pdf.table(table_rows, header: true, width: 700, column_widths: [ 80, 190, 95, 95, 90, 75, 75 ], cell_style: { overflow: :shrink_to_fit, min_font_size: 7 }) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.6
      cells.padding = [ 7, 7 ]
      cells.size = 10
      cells.text_color = TEXT
      row(0).background_color = QB_HEADER_BG
      row(0).font_style = :normal
      row(-1).background_color = QB_TOTAL_BG
      columns(2..3).align = :right
    end
    pdf.move_down 20
  end

  def render_detail_table(pdf, rows)
    start_new_page_if_needed(pdf, 150)
    pdf.font_size(12) { pdf.text "Payroll detail", style: :bold, color: TEXT }
    pdf.move_down 8

    table_rows = [ [ "Employee", "Gross pay", "Taxes", "Deductions", "Net pay", "Employer cost" ] ]
    rows.each do |row|
      table_rows << [ row[:employee_name], money(row[:gross_pay]), money(row[:taxes]), money(row[:deductions]), money(row[:net_pay]), money(row[:employer_cost]) ]
    end
    table_rows << [
      "Total",
      money(rows.sum { |row| row[:gross_pay].to_f }),
      money(rows.sum { |row| row[:taxes].to_f }),
      money(rows.sum { |row| row[:deductions].to_f }),
      money(rows.sum { |row| row[:net_pay].to_f }),
      money(rows.sum { |row| row[:employer_cost].to_f })
    ]

    pdf.table(table_rows, header: true, width: pdf.bounds.width) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.5
      cells.padding = [ 4, 5 ]
      cells.size = 8
      row(0).background_color = QB_HEADER_BG
      row(-1).background_color = QB_TOTAL_BG
      columns(1..5).align = :right
    end
  end

  def start_new_page_if_needed(pdf, height)
    pdf.start_new_page if pdf.cursor < height
  end

  def date(value)
    value&.strftime("%m/%d/%Y") || "—"
  end

  def money(value)
    "$#{format('%.2f', value.to_f)}"
  end

  def render_footer(pdf)
    pdf.repeat(:all) do
      pdf.canvas do
        pdf.fill_color MUTED
        pdf.font_size(8) { pdf.draw_text data.generated_at_label, at: [ pdf.bounds.width / 2 - 70, 18 ] }
      end
    end
    pdf.number_pages "<page>", at: [ pdf.bounds.right - 20, 18 ], size: 8, align: :right, color: MUTED
  end
end
