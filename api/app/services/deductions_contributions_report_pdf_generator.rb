# frozen_string_literal: true

require "prawn"
require "prawn/table"

# QuickBooks-style Deductions and Contributions report with Cornerstone detail.
# The first table mirrors QB's aggregate Description/Type/Employee/Company/Plan
# layout. Additional sections keep the richer employee-level and tax detail.
class DeductionsContributionsReportPdfGenerator
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

    if data.items.empty?
      pdf.text "No payroll items found.", style: :italic, color: MUTED
    else
      render_aggregate_table(pdf)
      render_employee_detail(pdf)
      render_tax_detail(pdf)
    end

    render_footer(pdf)
    pdf.render
  end

  def filename
    "deductions_contributions_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_header(pdf)
    pdf.fill_color TEXT
    pdf.font_size(13) { pdf.text company.name, align: :center }
    pdf.move_down 12
    pdf.font_size(20) { pdf.text "Deductions and Contributions Report", align: :center }
    pdf.move_down 12
    pdf.font_size(14) { pdf.text data.qb_date_range_label(include_locations: false), align: :center }
    pdf.move_down 24
  end

  def render_aggregate_table(pdf)
    rows = [ [ "Description", "Type", "Employee deductions", "Company contributions", "Plan total" ] ]
    data.aggregate_deduction_contribution_rows.each do |entry|
      employee_amount = entry.employee_amount.to_f
      company_amount = entry.company_amount.to_f
      rows << [ entry.description, entry.type, money(employee_amount), money(company_amount), money(employee_amount + company_amount) ]
    end

    total_employee = data.aggregate_deduction_contribution_rows.sum { |entry| entry.employee_amount.to_f }
    total_company = data.aggregate_deduction_contribution_rows.sum { |entry| entry.company_amount.to_f }
    rows << [ "Total", "", money(total_employee), money(total_company), money(total_employee + total_company) ]

    pdf.table(rows, header: true, width: pdf.bounds.width, column_widths: [ 120, 120, 90, 105, 105 ], cell_style: { overflow: :shrink_to_fit, min_font_size: 6 }) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.6
      cells.padding = [ 6, 5 ]
      cells.size = 9
      cells.text_color = TEXT
      row(0).background_color = QB_HEADER_BG
      row(0).font_style = :normal
      row(-1).background_color = QB_TOTAL_BG
      columns(2..4).align = :right
    end
    pdf.move_down 18
  end

  def render_employee_detail(pdf)
    return if data.deduction_contribution_entries.empty?

    start_new_page_if_needed(pdf, 140)
    section_title(pdf, "Employee detail")
    rows = [ [ "Employee", "Description", "Type", "Employee deductions", "Company contributions", "Plan total" ] ]
    employee_detail_entries.each do |entry|
      employee_amount = entry.employee_amount.to_f
      company_amount = entry.company_amount.to_f
      rows << [ entry.employee_name, entry.description, entry.type, money(employee_amount), money(company_amount), money(employee_amount + company_amount) ]
    end

    pdf.table(rows, header: true, width: pdf.bounds.width, column_widths: [ 95, 105, 115, 75, 85, 65 ], cell_style: { overflow: :shrink_to_fit, min_font_size: 5 }) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.5
      cells.padding = [ 4, 5 ]
      cells.size = 7.5
      row(0).background_color = QB_HEADER_BG
      columns(3..5).align = :right
    end
    pdf.move_down 16
  end

  def render_tax_detail(pdf)
    start_new_page_if_needed(pdf, 160)
    section_title(pdf, "Employee tax withholdings detail")
    rows = [ [ "Employee", "Federal Income", "Social Security", "Medicare", "Additional W/H", "Total taxes" ] ]
    data.tax_withholding_detail_rows.each do |row|
      rows << [ row[:employee_name], money(row[:fit]), money(row[:social_security]), money(row[:medicare]), money(row[:additional_withholding]), money(row[:total]) ]
    end
    totals = data.tax_withholding_detail_rows.each_with_object(Hash.new(0.0)) do |row, acc|
      %i[fit social_security medicare additional_withholding total].each { |key| acc[key] += row[key].to_f }
    end
    rows << [ "Total", money(totals[:fit]), money(totals[:social_security]), money(totals[:medicare]), money(totals[:additional_withholding]), money(totals[:total]) ]

    pdf.table(rows, header: true, width: pdf.bounds.width) do
      cells.border_color = QB_BORDER
      cells.border_width = 0.5
      cells.padding = [ 4, 5 ]
      cells.size = 7.5
      row(0).background_color = QB_HEADER_BG
      row(-1).background_color = QB_TOTAL_BG
      columns(1..5).align = :right
    end
  end

  def employee_detail_entries
    data.deduction_contribution_entries
      .group_by { |entry| [ entry.employee_name, entry.description, entry.type, entry.reporting_group ] }
      .map do |(employee_name, description, type, reporting_group), grouped|
        QuickbooksPayrollReportData::DeductionContributionEntry.new(
          employee_name: employee_name,
          description: description,
          type: type,
          reporting_group: reporting_group,
          employee_amount: grouped.sum { |entry| entry.employee_amount.to_f },
          company_amount: grouped.sum { |entry| entry.company_amount.to_f },
          bucket: grouped.first&.bucket,
          source: grouped.map(&:source).uniq.join(", ")
        )
      end
      .sort_by { |entry| [ entry.employee_name.to_s.downcase, entry.description.to_s.downcase ] }
  end

  # Compatibility helpers used by existing specs and useful for targeted tests.
  def deduction_amount_for_label(item, label, category)
    data.deduction_contribution_entries_for_item(item)
      .select { |entry| entry.bucket == category && entry.description == label }
      .sum { |entry| entry.employee_amount.to_f }
  end

  def employee_deductions_total(item)
    data.deduction_contribution_entries_for_item(item).sum { |entry| entry.employee_amount.to_f }
  end

  def section_title(pdf, title)
    pdf.fill_color TEXT
    pdf.font_size(13) { pdf.text title, style: :bold }
    pdf.move_down 8
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
