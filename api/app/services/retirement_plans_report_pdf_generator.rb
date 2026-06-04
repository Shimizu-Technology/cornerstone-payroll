# frozen_string_literal: true

require "prawn"
require "prawn/table"

# QuickBooks-style Retirement Plans Report. Sections are driven by explicit
# reporting_group metadata when present, with safe retirement/401(k) inference
# only for already-retirement-specific legacy data.
class RetirementPlansReportPdfGenerator
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
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [ 36, 36, 46, 36 ])
    render_header(pdf)

    rows = data.retirement_rows
    if rows.empty?
      pdf.text "No retirement contributions found for this pay period.", style: :italic, color: MUTED
    else
      render_sections(pdf, rows)
      render_provider_summary(pdf, rows)
    end

    render_footer(pdf)
    pdf.render
  end

  def filename
    "retirement_plans_report_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_header(pdf)
    pdf.fill_color TEXT
    pdf.font_size(13) { pdf.text company.name, align: :center }
    pdf.move_down 12
    pdf.font_size(20) { pdf.text "Retirement plans report", align: :center }
    pdf.move_down 12
    pdf.font_size(14) { pdf.text data.qb_date_range_label(include_locations: false), align: :center }
    pdf.move_down 24
  end

  def render_sections(pdf, rows)
    rows.group_by(&:group).sort_by { |group, _| retirement_group_rank(group) }.each do |group, group_rows|
      start_new_page_if_needed(pdf, 160)
      pdf.font_size(18) { pdf.text PayrollReportingGroups.label(group) || group.to_s, color: TEXT }
      pdf.move_down 10

      table_rows = [ [ "Employee", "Employee deductions", "Company contributions", "Plan total" ] ]
      group_rows.each do |row|
        table_rows << [ row.employee_name, money(row.employee_amount), money(row.company_amount), money(row.employee_amount.to_f + row.company_amount.to_f) ]
      end
      table_rows << [
        "Total",
        money(group_rows.sum { |row| row.employee_amount.to_f }),
        money(group_rows.sum { |row| row.company_amount.to_f }),
        money(group_rows.sum { |row| row.employee_amount.to_f + row.company_amount.to_f })
      ]

      pdf.table(table_rows, header: true, width: pdf.bounds.width, column_widths: [ 210, 110, 130, 90 ], cell_style: { overflow: :shrink_to_fit, min_font_size: 6 }) do
        cells.border_color = QB_BORDER
        cells.border_width = 0.6
        cells.padding = [ 7, 8 ]
        cells.size = 9
        cells.text_color = TEXT
        row(0).background_color = QB_HEADER_BG
        row(0).font_style = :normal
        row(-1).background_color = QB_TOTAL_BG
        columns(1..3).align = :right
      end
      pdf.move_down 24
    end
  end

  def render_provider_summary(pdf, rows)
    start_new_page_if_needed(pdf, 90)
    total_employee = rows.sum { |row| row.employee_amount.to_f }
    total_company = rows.sum { |row| row.company_amount.to_f }

    pdf.font_size(10) do
      pdf.text "Total to be deducted from bank account for retirement provider:", style: :bold, color: TEXT
      pdf.text "Employee contributions: #{money(total_employee)}"
      pdf.text "Employer contributions: #{money(total_company)}"
      pdf.text "Combined total: #{money(total_employee + total_company)}", style: :bold
    end
  end

  def retirement_group_rank(group)
    case group
    when PayrollReportingGroups::GROUP_401K_PRE_TAX
      0
    when PayrollReportingGroups::GROUP_401K_AFTER_TAX
      1
    when PayrollReportingGroups::GROUP_RETIREMENT_OTHER
      2
    else
      99
    end
  end

  def start_new_page_if_needed(pdf, height)
    pdf.start_new_page if pdf.cursor < height
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
