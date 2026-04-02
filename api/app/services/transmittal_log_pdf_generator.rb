# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a Transmittal Log PDF — the cover document listing everything
# being delivered to the client for a pay period.
# Layout mirrors the Excel transmittal template used by Cornerstone.
class TransmittalLogPdfGenerator
  HEADER_COLOR = "2B4090"
  TEXT_MUTED   = "666666"

  attr_reader :pay_period, :company, :options

  # @param pay_period [PayPeriod]
  # @param options [Hash] optional overrides:
  #   - preparer_name: "Dafne M Shimizu, CPA"
  #   - notes: ["EFTPS payment...", "401K upload..."]
  #   - report_list: ["Retirement Plans Report", ...]
  def initialize(pay_period, options = {})
    @pay_period = pay_period
    @company = pay_period.company
    @options = options
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [36, 50, 36, 50])
    render_document(pdf)
    pdf.render
  end

  def filename
    "transmittal_log_#{pay_period.start_date}_to_#{pay_period.end_date}.pdf"
  end

  private

  def render_document(pdf)
    render_header(pdf)
    render_dates(pdf)
    render_documents_provided(pdf)
    render_tax_obligations(pdf)
    render_notes(pdf)
  end

  def render_header(pdf)
    preparer = options[:preparer_name] || "Cornerstone Tax Services"

    y_start = pdf.cursor

    pdf.font_size(14) { pdf.text preparer, style: :bold, color: HEADER_COLOR }
    pdf.move_down 2
    pdf.font_size(12) { pdf.text "Transmittal", style: :bold }
    pdf.move_down 2
    pdf.font_size(11) { pdf.text company.name }

    pdf.font_size(9) do
      pdf.bounding_box([pdf.bounds.width - 200, y_start], width: 200) do
        pdf.text "Received by: _____________________"
        pdf.move_down 6
        pdf.text "Date Rec'd: ______________________"
      end
    end
    pdf.move_down 16
  end

  def render_dates(pdf)
    pdf.font_size(10) do
      label_width = 80
      pdf.text_box "Date:", at: [0, pdf.cursor], width: label_width
      pdf.text_box pay_period.pay_date.strftime("%m/%d/%Y"), at: [label_width, pdf.cursor]
      pdf.move_down 16
      pdf.text_box "Pay Day:", at: [0, pdf.cursor], width: label_width
      pdf.text_box pay_period.pay_date.strftime("%m/%d/%Y"), at: [label_width, pdf.cursor]
      pdf.move_down 16
      pdf.text_box "PPE:", at: [0, pdf.cursor], width: label_width
      pdf.text_box "#{pay_period.start_date.strftime('%m/%d/%Y')} - #{pay_period.end_date.strftime('%m/%d/%Y')}", at: [label_width, pdf.cursor]
      pdf.move_down 16
    end
    pdf.move_down 10
  end

  def render_documents_provided(pdf)
    pdf.font_size(11) { pdf.text "Documents Provided to Client:", style: :bold }
    pdf.move_down 8

    item_num = 0
    ne_check_overrides = options[:non_employee_check_numbers] || {}

    # 1) Payroll checks
    check_numbers = pay_period.payroll_items
      .where(voided: false)
      .where.not(check_number: nil)
      .pluck(:check_number)
      .sort_by(&:to_i)

    if check_numbers.any?
      first_num = options[:check_number_first].presence || check_numbers.first
      last_num = options[:check_number_last].presence || check_numbers.last

      item_num += 1
      pdf.font_size(10) do
        pdf.text "#{item_num})  Payroll Checks", style: :bold
        pdf.indent(30) do
          pdf.text "Number of Checks:  #{check_numbers.size}"
          pdf.text "Checks #  #{first_num}  through  #{last_num}"
        end
      end
      pdf.move_down 8
    end

    # 2+) Non-employee checks
    ne_checks = pay_period.non_employee_checks.active.order(:id)
    ne_checks.each do |check|
      item_num += 1
      overridden_num = ne_check_overrides[check.id]
      check_label = overridden_num.present? ? overridden_num : (check.check_number.present? ? check.check_number : "____")
      type_label = check.check_type.present? ? " (#{check.check_type.titleize})" : ""

      pdf.font_size(10) do
        pdf.text "#{item_num})  Check for #{check.payable_to}#{type_label}", style: :bold
        pdf.indent(30) do
          pdf.text "Check #:  #{check_label}"
          pdf.text "Payable to:  #{check.payable_to}"
          pdf.text "Amount:  #{fmt(check.amount)}"
          pdf.text "For:  #{check.memo}" if check.memo.present?
          pdf.text "Description/Memo:  #{check.description}" if check.description.present?
        end
      end
      pdf.move_down 6
    end

    # Reports section
    reports = options[:report_list] || default_report_list
    if reports.any?
      item_num += 1
      pdf.font_size(10) do
        pdf.text "#{item_num})  Reports:", style: :bold
        pdf.indent(30) do
          reports.each_with_index do |report, idx|
            pdf.text "#{idx + 1}  #{report}"
          end
        end
      end
      pdf.move_down 8
    end
  end

  def render_tax_obligations(pdf)
    items = pay_period.payroll_items.where(voided: false)
    total_fit  = items.sum(:withholding_tax)
    emp_ss     = items.sum(:social_security_tax)
    er_ss      = items.sum(:employer_social_security_tax)
    emp_med    = items.sum(:medicare_tax)
    er_med     = items.sum(:employer_medicare_tax)
    total_fica = emp_ss + er_ss + emp_med + er_med
    total_drt  = total_fit + total_fica

    return unless total_drt > 0

    pdf.move_down 4
    pdf.stroke_horizontal_rule
    pdf.move_down 8

    pdf.font_size(11) { pdf.text "Employer Tax Obligations", style: :bold }
    pdf.font_size(8) { pdf.text "Amounts Cornerstone must deposit with Guam DRT", color: TEXT_MUTED }
    pdf.move_down 6

    col_width = (pdf.bounds.width - 20) / 2

    pdf.font_size(9) do
      y_top = pdf.cursor

      # Left column: FIT
      pdf.bounding_box([0, y_top], width: col_width) do
        pdf.text "FEDERAL / GUAM INCOME TAX", style: :bold, size: 8
        pdf.move_down 4
        tax_row(pdf, "Employee FIT Withheld", fmt(total_fit))
        pdf.move_down 3
        pdf.stroke_horizontal_rule
        pdf.move_down 3
        tax_row(pdf, "FIT Subtotal", fmt(total_fit), bold: true)
      end

      # Right column: FICA
      pdf.bounding_box([col_width + 20, y_top], width: col_width) do
        pdf.text "SOCIAL SECURITY & MEDICARE (FICA)", style: :bold, size: 8
        pdf.move_down 4
        tax_row(pdf, "Employee Social Security (6.2%)", fmt(emp_ss))
        tax_row(pdf, "Employer Social Security (6.2%)", fmt(er_ss))
        tax_row(pdf, "Employee Medicare (1.45%)", fmt(emp_med))
        tax_row(pdf, "Employer Medicare (1.45%)", fmt(er_med))
        pdf.move_down 3
        pdf.stroke_horizontal_rule
        pdf.move_down 3
        tax_row(pdf, "FICA Subtotal", fmt(total_fica), bold: true)
      end
    end

    pdf.move_down 10
    pdf.font_size(11) { pdf.text "Total DRT Deposit", style: :bold }
    pdf.font_size(8) { pdf.text "FIT + Employee & Employer SS & Medicare", color: TEXT_MUTED }
    pdf.move_down 2
    pdf.font_size(14) { pdf.text fmt(total_drt), style: :bold, color: "B45309" }
    pdf.move_down 8
  end

  def tax_row(pdf, label, amount, bold: false)
    style = bold ? :bold : :normal
    label_w = pdf.bounds.width - 70
    pdf.text_box label, at: [0, pdf.cursor], width: label_w, style: style
    pdf.text_box amount, at: [label_w, pdf.cursor], width: 70, align: :right, style: style
    pdf.move_down 12
  end

  def render_notes(pdf)
    notes = options[:notes]
    return if notes.blank?

    pdf.stroke_horizontal_rule
    pdf.move_down 8

    pdf.font_size(10) do
      pdf.text "Notes:", style: :bold
      pdf.move_down 4
      Array(notes).each_with_index do |note, idx|
        pdf.text "#{idx + 1})  #{note}"
        pdf.move_down 2
      end
    end
    pdf.move_down 4
  end

  def default_report_list
    [
      "Payroll Summary by Employee",
      "Deductions and Contributions Report",
      "Paycheck History",
      "Retirement Plans Report",
      "Employee Installment Loan Report"
    ]
  end

  def fmt(value)
    number = format("%.2f", value.to_f)
    parts = number.split(".")
    parts[0] = parts[0].reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    "$#{parts.join('.')}"
  end
end
