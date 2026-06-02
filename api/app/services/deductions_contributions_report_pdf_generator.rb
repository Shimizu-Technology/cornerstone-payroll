# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a Deductions and Contributions Report PDF.
# Shows all deductions and employer contributions aggregated by category/type,
# with per-employee breakdowns.
class DeductionsContributionsReportPdfGenerator
  include PdfFooter

  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :pay_period, :company

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
  end

  def generate
    items = pay_period.payroll_items
      .includes(:employee, :payroll_item_field_entries, payroll_item_deductions: :deduction_type)
      .not_voided
      .order("employees.last_name ASC, employees.first_name ASC")

    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [36, 36, 50, 36])
    render_document(pdf, items.to_a)
  end

  def filename
    "deductions_contributions_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_document(pdf, items)
    render_header(pdf)

    if items.empty?
      pdf.text "No payroll items found.", style: :italic, color: TEXT_MUTED
      return
    end

    render_employee_taxes_section(pdf, items)
    render_deductions_section(pdf, items, "pre_tax", "Pre-Tax Deductions")
    render_deductions_section(pdf, items, "post_tax", "After-Tax Deductions")
    render_employer_section(pdf, items)
    render_grand_totals(pdf, items)

    render_with_footer(pdf,
      "#{company.name} \u2014 Deductions & Contributions \u2014 #{pay_period.start_date} to #{pay_period.end_date} \u2014 CONFIDENTIAL"
    )
  end

  def render_header(pdf)
    pdf.font_size(16) { pdf.text company.name, style: :bold, color: HEADER_BG }
    pdf.font_size(11) { pdf.text "Deductions and Contributions Report", color: TEXT_DARK }
    pdf.font_size(9) do
      pdf.text "Pay Period: #{pay_period.start_date.strftime('%b %d, %Y')} – #{pay_period.end_date.strftime('%b %d, %Y')}  |  Pay Date: #{pay_period.pay_date.strftime('%b %d, %Y')}", color: TEXT_MUTED
    end
    pdf.move_down 14
  end

  def render_employee_taxes_section(pdf, items)
    pdf.font_size(11) { pdf.text "Employee Tax Withholdings", style: :bold, color: HEADER_BG }
    pdf.move_down 4

    header = build_header(["Employee", "FIT", "Social Security", "Medicare", "Total Taxes"])
    rows = items.map do |item|
      employee_row(item.employee_full_name,
        [item.withholding_tax, item.social_security_tax, item.medicare_tax,
         item.withholding_tax.to_f + item.social_security_tax.to_f + item.medicare_tax.to_f])
    end

    totals = totals_row("TOTALS",
      [items.sum { |i| i.withholding_tax.to_f },
       items.sum { |i| i.social_security_tax.to_f },
       items.sum { |i| i.medicare_tax.to_f },
       items.sum { |i| i.withholding_tax.to_f + i.social_security_tax.to_f + i.medicare_tax.to_f }])

    render_table(pdf, [header] + rows + [totals])
    pdf.move_down 12
  end

  def render_deductions_section(pdf, items, category, title)
    all_labels = items.flat_map { |item|
      item.payroll_item_deductions.select { |d| d.category == category }.map(&:label) +
        employee_payroll_field_deduction_entries(item, category).map(&:label)
    }.uniq.sort
    if category == "post_tax"
      custom_labels = items.flat_map { |item|
        Array(item.custom_deductions).filter_map do |deduction|
          next unless deduction["amount"].to_f.positive?

          deduction["label"].presence || "Other Deduction"
        end
      }
      all_labels = (all_labels + custom_labels).uniq.sort
    end

    return if all_labels.empty?

    pdf.font_size(11) { pdf.text title, style: :bold, color: HEADER_BG }
    pdf.move_down 4

    header = build_header(["Employee"] + all_labels + ["Total"])
    rows = items.map do |item|
      amounts = all_labels.map do |label|
        deduction_amount_for_label(item, label, category)
      end
      employee_row(item.employee_full_name, amounts + [amounts.sum])
    end

    col_totals = all_labels.map.with_index do |_, idx|
      rows.sum { |r| r[idx + 1][:content].to_s.gsub(/[$,]/, "").to_f }
    end
    totals = totals_row("TOTALS", col_totals + [col_totals.sum])

    render_table(pdf, [header] + rows + [totals])
    pdf.move_down 12
  end

  def render_employer_section(pdf, items)
    pdf.font_size(11) { pdf.text "Employer Taxes & Contributions", style: :bold, color: HEADER_BG }
    pdf.move_down 4

    field_labels = items.flat_map { |item| employer_payroll_field_entries(item).map(&:label) }.uniq.sort
    header = build_header(["Employee", "Employer SS", "Employer Medicare", "401(k) Match"] + field_labels + ["Total"])
    rows = items.map do |item|
      ss = item.employer_social_security_tax.to_f
      med = item.employer_medicare_tax.to_f
      ret = item.employer_retirement_match.to_f + item.employer_roth_retirement_match.to_f
      field_amounts = field_labels.map { |label| employer_payroll_field_entries(item).select { |entry| entry.label == label }.sum(&:amount).to_f }
      employee_row(item.employee_full_name, [ss, med, ret] + field_amounts + [ss + med + ret + field_amounts.sum])
    end

    field_totals = field_labels.map { |label| items.sum { |i| employer_payroll_field_entries(i).select { |entry| entry.label == label }.sum(&:amount).to_f } }
    totals = totals_row("TOTALS", [
      items.sum { |i| i.employer_social_security_tax.to_f },
      items.sum { |i| i.employer_medicare_tax.to_f },
      items.sum { |i| i.employer_retirement_match.to_f + i.employer_roth_retirement_match.to_f },
      *field_totals,
      items.sum { |i| i.employer_social_security_tax.to_f + i.employer_medicare_tax.to_f +
                       i.employer_retirement_match.to_f + i.employer_roth_retirement_match.to_f } + field_totals.sum
    ])

    render_table(pdf, [header] + rows + [totals])
    pdf.move_down 12
  end

  def employer_payroll_field_entries(item)
    item.payroll_item_field_entries.select { |entry| entry.active? && entry.tax_treatment == "employer_contribution" }
  end

  def render_grand_totals(pdf, items)
    pdf.stroke_color HEADER_BG
    pdf.line_width = 2
    pdf.stroke_horizontal_rule
    pdf.line_width = 1
    pdf.move_down 6

    total_emp_taxes = items.sum { |i| i.withholding_tax.to_f + i.social_security_tax.to_f + i.medicare_tax.to_f }
    total_deductions = items.sum { |i| employee_deductions_total(i) }
    total_employer = items.sum { |i|
      i.employer_social_security_tax.to_f + i.employer_medicare_tax.to_f +
      i.employer_retirement_match.to_f + i.employer_roth_retirement_match.to_f + employer_payroll_field_entries(i).sum(&:amount).to_f
    }

    pdf.font_size(10) do
      pdf.text "Grand Totals", style: :bold, color: HEADER_BG
      pdf.move_down 4
      pdf.text "Total Employee Taxes: #{fmt(total_emp_taxes)}"
      pdf.text "Total Employee Deductions: #{fmt(total_deductions)}"
      pdf.text "Total Employer Contributions: #{fmt(total_employer)}"
      pdf.move_down 2
      pdf.text "Combined Total: #{fmt(total_emp_taxes + total_deductions + total_employer)}", style: :bold
    end
  end

  def build_header(labels)
    labels.map.with_index do |label, idx|
      {
        content: label,
        background_color: HEADER_BG,
        text_color: "FFFFFF",
        font_style: :bold,
        align: idx.zero? ? :left : :right
      }
    end
  end

  def employee_row(name, amounts)
    [{ content: name }] + amounts.map { |a| { content: fmt(a), align: :right } }
  end

  def totals_row(label, amounts)
    [{ content: label, font_style: :bold, background_color: SECTION_BG }] +
      amounts.map { |a| { content: fmt(a), align: :right, font_style: :bold, background_color: SECTION_BG } }
  end

  def deduction_amount_for_label(item, label, category)
    field_entries = employee_payroll_field_deduction_entries(item, category).select { |entry| entry.label == label }
    field_amounts = field_entries.map { |entry| entry.amount.to_f.round(2) }
    amount = item.payroll_item_deductions
      .select { |deduction| deduction.label == label && deduction.category == category }
      .reject { |deduction| consume_matching_amount?(field_amounts, deduction.amount.to_f) }
      .sum(&:amount)
      .to_f
    amount += field_entries.sum { |entry| entry.amount.to_f }
    return amount unless category == "post_tax"

    amount + Array(item.custom_deductions).sum do |deduction|
      deduction_label = deduction["label"].presence || "Other Deduction"
      deduction_label == label ? deduction["amount"].to_f : 0
    end
  end

  def employee_deductions_total(item)
    %w[pre_tax post_tax].sum do |category|
      labels = item.payroll_item_deductions.select { |deduction| deduction.category == category }.map(&:label) +
        employee_payroll_field_deduction_entries(item, category).map(&:label)
      if category == "post_tax"
        labels += Array(item.custom_deductions).filter_map do |deduction|
          next unless deduction["amount"].to_f.positive?

          deduction["label"].presence || "Other Deduction"
        end
      end
      labels.uniq.sum { |label| deduction_amount_for_label(item, label, category) }
    end
  end

  def employee_payroll_field_deduction_entries(item, category)
    treatment = category == "pre_tax" ? "pre_tax_deduction" : "post_tax_deduction"
    item.payroll_item_field_entries.select { |entry| entry.active? && entry.tax_treatment == treatment }
  end

  def consume_matching_amount?(amounts, amount)
    index = amounts.index(amount.round(2))
    return false unless index

    amounts.delete_at(index)
    true
  end

  def render_table(pdf, data)
    pdf.table(data,
      width: pdf.bounds.width,
      cell_style: { size: 7, padding: [3, 4], border_color: BORDER_GRAY, overflow: :shrink_to_fit }
    )
  end

  def fmt(value)
    val = value.to_f
    if val < 0
      "-$#{format('%.2f', val.abs)}"
    else
      "$#{format('%.2f', val)}"
    end
  end
end
