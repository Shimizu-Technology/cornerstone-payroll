# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a detailed Payroll Summary by Employee PDF modeled after the QuickBooks report.
# Shows per-employee breakdown: earnings, pre-tax deductions, taxes, after-tax deductions,
# net pay, employer taxes, employer contributions, and total payroll cost.
class PayrollSummaryByEmployeePdfGenerator
  include PdfFooter

  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  ALT_ROW_BG  = "F9FAFB"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  EMPLOYEES_PER_PAGE = 5

  attr_reader :pay_period, :company

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
  end

  def generate
    items = pay_period.payroll_items
      .includes(:employee, :payroll_item_earnings, payroll_item_deductions: :deduction_type)
      .where(voided: false)
      .order("employees.last_name ASC, employees.first_name ASC")

    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :landscape, margin: [30, 30, 44, 30])
    render_document(pdf, items)
  end

  def filename
    "payroll_summary_by_employee_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_document(pdf, items)
    all_items = items.to_a
    return render_empty(pdf) if all_items.empty?

    totals = compute_totals(all_items)
    all_items.each_slice(EMPLOYEES_PER_PAGE).with_index do |group, page_idx|
      pdf.start_new_page unless page_idx.zero?
      render_page(pdf, group, totals, page_idx, (all_items.size.to_f / EMPLOYEES_PER_PAGE).ceil)
    end

    render_with_footer(pdf,
      "#{company.name} \u2014 Payroll Summary by Employee \u2014 #{pay_period.start_date} to #{pay_period.end_date} \u2014 CONFIDENTIAL"
    )
  end

  def render_page(pdf, group, totals, page_idx, total_pages)
    render_header(pdf)

    col_width = (pdf.bounds.width - 140) / group.size
    label_width = 140

    # Hours section
    render_section_header(pdf, "Hours")
    render_employee_earnings_rows(pdf, group, label_width, col_width, "hours")

    # Gross / Earnings section
    render_section_header(pdf, "Gross Earnings")
    render_employee_earnings_rows(pdf, group, label_width, col_width, "earnings")

    # Pre-tax deductions
    render_section_header(pdf, "Pre-tax Deductions")
    render_deduction_rows(pdf, group, label_width, col_width, "pre_tax")

    # Adjusted Gross
    render_summary_row(pdf, "Adjusted Gross", group, label_width, col_width) { |item|
      adjusted = item.gross_pay.to_f - item.retirement_payment.to_f - item.roth_retirement_payment.to_f
      fmt(adjusted)
    }
    pdf.move_down 4

    # Employee Taxes
    render_section_header(pdf, "Employee Taxes")
    render_tax_rows(pdf, group, label_width, col_width)

    # After-tax deductions
    render_section_header(pdf, "After-tax Deductions")
    render_deduction_rows(pdf, group, label_width, col_width, "post_tax")

    # Net Pay
    render_summary_row(pdf, "Net Pay", group, label_width, col_width, bold: true) { |item|
      fmt(item.net_pay)
    }
    pdf.move_down 8

    # Employer Taxes & Contributions
    render_section_header(pdf, "Employer Taxes & Contributions")
    render_employer_rows(pdf, group, label_width, col_width)

    # Total Payroll Cost
    render_summary_row(pdf, "Total Payroll Cost", group, label_width, col_width, bold: true) { |item|
      total_cost = item.gross_pay.to_f + item.employer_social_security_tax.to_f +
                   item.employer_medicare_tax.to_f + item.employer_retirement_match.to_f +
                   item.employer_roth_retirement_match.to_f
      fmt(total_cost)
    }
  end

  def render_header(pdf)
    pdf.font_size(14) { pdf.text company.name, style: :bold, color: HEADER_BG }
    pdf.font_size(10) { pdf.text "Payroll Summary by Employee", color: TEXT_DARK }
    period_text = "Pay Period: #{pay_period.start_date.strftime('%b %d, %Y')} – #{pay_period.end_date.strftime('%b %d, %Y')}  |  Pay Date: #{pay_period.pay_date.strftime('%b %d, %Y')}"
    pdf.font_size(8) { pdf.text period_text, color: TEXT_MUTED }
    pdf.move_down 10
  end

  def render_section_header(pdf, title)
    pdf.fill_color HEADER_BG
    pdf.font_size(9) { pdf.text title, style: :bold, color: HEADER_BG }
    pdf.fill_color TEXT_DARK
    pdf.move_down 2
  end

  def render_employee_earnings_rows(pdf, group, label_width, col_width, mode)
    if mode == "hours"
      render_labeled_row(pdf, "Total Hours", group, label_width, col_width) { |item|
        h = item.total_hours.round(2)
        h > 0 ? "#{h}h" : "—"
      }
    else
      render_labeled_row(pdf, "Gross Pay", group, label_width, col_width) { |item|
        fmt(item.gross_pay)
      }

      earnings_labels = group.flat_map { |item|
        item.payroll_item_earnings.map(&:label)
      }.uniq

      earnings_labels.each do |label|
        render_labeled_row(pdf, label, group, label_width, col_width) { |item|
          earning = item.payroll_item_earnings.find { |e| e.label == label }
          earning ? fmt(earning.amount) : "—"
        }
      end
    end
  end

  def render_deduction_rows(pdf, group, label_width, col_width, category)
    deduction_labels = group.flat_map { |item|
      item.payroll_item_deductions.select { |d| d.category == category }.map(&:label)
    }.uniq

    if deduction_labels.empty?
      render_labeled_row(pdf, "(none)", group, label_width, col_width) { |_| "—" }
      return
    end

    deduction_labels.each do |label|
      render_labeled_row(pdf, label, group, label_width, col_width) { |item|
        ded = item.payroll_item_deductions.find { |d| d.label == label && d.category == category }
        ded ? fmt(-ded.amount) : "—"
      }
    end

    render_labeled_row(pdf, "Subtotal", group, label_width, col_width, bold: true) { |item|
      total = item.payroll_item_deductions.select { |d| d.category == category }.sum(&:amount)
      total > 0 ? fmt(-total) : "—"
    }
  end

  def render_tax_rows(pdf, group, label_width, col_width)
    [
      ["Federal/Guam Income Tax", ->(item) { item.withholding_tax }],
      ["Social Security",         ->(item) { item.social_security_tax }],
      ["Medicare",                 ->(item) { item.medicare_tax }]
    ].each do |label, accessor|
      render_labeled_row(pdf, label, group, label_width, col_width) { |item|
        val = accessor.call(item).to_f
        val > 0 ? fmt(-val) : "—"
      }
    end

    render_labeled_row(pdf, "Total Employee Taxes", group, label_width, col_width, bold: true) { |item|
      total = item.withholding_tax.to_f + item.social_security_tax.to_f + item.medicare_tax.to_f
      fmt(-total)
    }
  end

  def render_employer_rows(pdf, group, label_width, col_width)
    [
      ["Social Security Employer",  ->(item) { item.employer_social_security_tax }],
      ["Medicare Employer",          ->(item) { item.employer_medicare_tax }],
      ["401(k) Employer Match",      ->(item) { item.employer_retirement_match }],
      ["Roth 401(k) Employer Match", ->(item) { item.employer_roth_retirement_match }]
    ].each do |label, accessor|
      render_labeled_row(pdf, label, group, label_width, col_width) { |item|
        val = accessor.call(item).to_f
        val > 0 ? fmt(val) : "—"
      }
    end

    render_labeled_row(pdf, "Total Employer Cost", group, label_width, col_width, bold: true) { |item|
      total = item.employer_social_security_tax.to_f + item.employer_medicare_tax.to_f +
              item.employer_retirement_match.to_f + item.employer_roth_retirement_match.to_f
      fmt(total)
    }
  end

  def render_labeled_row(pdf, label, group, label_width, col_width, bold: false)
    return if pdf.cursor < 20
    pdf.start_new_page if pdf.cursor < 20

    y = pdf.cursor
    style = bold ? :bold : :normal
    pdf.font_size(7) do
      pdf.bounding_box([0, y], width: label_width, height: 12) do
        pdf.text label, style: style, color: TEXT_DARK, overflow: :shrink_to_fit
      end
      group.each_with_index do |item, idx|
        x = label_width + (idx * col_width)
        pdf.bounding_box([x, y], width: col_width, height: 12) do
          pdf.text(yield(item), align: :right, style: style, color: TEXT_DARK)
        end
      end
    end
    pdf.move_down 1
  end

  def render_summary_row(pdf, label, group, label_width, col_width, bold: false)
    pdf.stroke_color BORDER_GRAY
    pdf.stroke_horizontal_line 0, pdf.bounds.width
    pdf.move_down 2
    render_labeled_row(pdf, label, group, label_width, col_width, bold: bold) { |item| yield(item) }
    pdf.move_down 2
  end

  def render_empty(pdf)
    render_header(pdf)
    pdf.text "No payroll items found for this pay period.", style: :italic, color: TEXT_MUTED
  end

  def compute_totals(items)
    {
      gross: items.sum { |i| i.gross_pay.to_f },
      net: items.sum { |i| i.net_pay.to_f },
      withholding: items.sum { |i| i.withholding_tax.to_f },
      ss: items.sum { |i| i.social_security_tax.to_f },
      medicare: items.sum { |i| i.medicare_tax.to_f },
      employer_ss: items.sum { |i| i.employer_social_security_tax.to_f },
      employer_medicare: items.sum { |i| i.employer_medicare_tax.to_f }
    }
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
