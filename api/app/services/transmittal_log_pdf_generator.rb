# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates a Transmittal Log PDF — the cover document listing everything
# being delivered to the client for a pay period.
class TransmittalLogPdfGenerator
  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :pay_period, :company, :options

  # @param pay_period [PayPeriod]
  # @param options [Hash] optional overrides:
  #   - preparer_name: "Dafne M Shimizu, CPA"
  #   - notes: ["EFTPS payment to be done...", "401K upload..."]
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
    render_payroll_checks(pdf)
    render_non_employee_checks(pdf)
    render_reports_list(pdf)
    render_notes(pdf)
    render_signature_block(pdf)
  end

  def render_header(pdf)
    preparer = options[:preparer_name] || "Cornerstone Tax Services"

    pdf.font_size(14) { pdf.text preparer, style: :bold, color: HEADER_BG }
    pdf.font_size(12) { pdf.text "Transmittal", style: :bold }
    pdf.font_size(11) { pdf.text company.name }
    pdf.move_down 12

    # Received by / Date Rec'd (signature fields)
    pdf.font_size(9) do
      y = pdf.cursor
      pdf.bounding_box([pdf.bounds.width - 200, y], width: 200) do
        pdf.text "Received by: _____________________"
        pdf.move_down 4
        pdf.text "Date Rec'd: ______________________"
      end
    end
    pdf.move_down 8
  end

  def render_dates(pdf)
    pdf.font_size(10) do
      pdf.text "Date:     #{pay_period.pay_date.strftime('%m/%d/%Y')}"
      pdf.text "Pay Day:  #{pay_period.pay_date.strftime('%m/%d/%Y')}"
      pdf.text "PPE:      #{pay_period.end_date.strftime('%m/%d/%Y')}"
    end
    pdf.move_down 10
    pdf.font_size(11) { pdf.text "Documents Provided to Client:", style: :bold }
    pdf.move_down 6
  end

  def render_payroll_checks(pdf)
    items = pay_period.payroll_items
      .where(voided: false)
      .where.not(check_number: nil)
      .order(:check_number)

    return unless items.any?

    check_numbers = items.pluck(:check_number).sort_by { |n| n.to_i }

    pdf.font_size(10) do
      pdf.text "1)  Payroll Checks", style: :bold
      pdf.indent(30) do
        pdf.text "Number of Checks: #{check_numbers.size}"
        if check_numbers.any?
          pdf.text "Checks # #{check_numbers.first} through #{check_numbers.last}"
        end
      end
    end
    pdf.move_down 8
  end

  def render_non_employee_checks(pdf)
    ne_checks = pay_period.non_employee_checks.active.order(:id)
    return unless ne_checks.any?

    ne_checks.each_with_index do |check, idx|
      item_num = idx + 2 # starts at 2 since payroll checks are 1

      pdf.font_size(10) do
        pdf.text "#{item_num})  Check ##{check.check_number || '____'}", style: :bold
        pdf.indent(30) do
          pdf.text "Amount:  #{fmt(check.amount)}"
          pdf.text "Payable to:  #{check.payable_to}"
          pdf.text "For:  #{check.memo}" if check.memo.present?
          if check.description.present?
            pdf.text "Description/Memo:  #{check.description}"
          end
          if check.reference_number.present?
            pdf.text "Reference:  #{check.reference_number}"
          end
        end
      end
      pdf.move_down 6
    end
  end

  def render_reports_list(pdf)
    reports = options[:report_list] || default_report_list
    return if reports.empty?

    pdf.move_down 4
    next_num = 2 + pay_period.non_employee_checks.active.count
    pdf.font_size(10) do
      pdf.text "#{next_num})  Reports:", style: :bold
      pdf.indent(30) do
        reports.each_with_index do |report, idx|
          pdf.text "#{idx + 1}. #{report}"
        end
      end
    end
    pdf.move_down 8
  end

  def render_notes(pdf)
    notes = options[:notes]
    return if notes.blank?

    pdf.move_down 4
    pdf.font_size(10) do
      pdf.text "Notes:", style: :bold
      Array(notes).each_with_index do |note, idx|
        pdf.text "#{idx + 1})  #{note}"
      end
    end
    pdf.move_down 4

    # Auto-calculate key totals for notes
    items = pay_period.payroll_items.where(voided: false)
    total_fit = items.sum(:withholding_tax).to_f
    total_ss = items.sum(:social_security_tax).to_f + items.sum(:employer_social_security_tax).to_f
    total_med = items.sum(:medicare_tax).to_f + items.sum(:employer_medicare_tax).to_f
    eftps_total = total_ss + total_med

    if eftps_total > 0
      pdf.font_size(9) do
        pdf.text "  EFTPS Payment (SS + Medicare): #{fmt(eftps_total)}", color: TEXT_MUTED
        pdf.text "  FIT Deposit Total: #{fmt(total_fit)}", color: TEXT_MUTED
      end
    end
  end

  def render_signature_block(pdf)
    pdf.move_down 30
    pdf.font_size(9) do
      pdf.text "Prepared by: _________________________  Date: _______________"
      pdf.move_down 12
      pdf.text "Reviewed by: _________________________  Date: _______________"
    end
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
    "$#{format('%.2f', value.to_f)}"
  end
end
