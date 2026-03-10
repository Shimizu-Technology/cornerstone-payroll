# frozen_string_literal: true

require "prawn"
require "prawn/table"
require "active_support/number_helper"
require_relative "../../lib/number_to_words"

# Generates a 3-part letter-size PDF for pre-printed payroll check stock.
#
# Layout (bottom-check, the most common US payroll configuration):
#   Page top (0"–3.67")  : Employee stub (earnings + deductions detail)
#   Middle (3.67"–7.33") : Employer stub (duplicate of employee stub)
#   Bottom (7.33"–11")   : Check face (payee, date, amount, signature line)
#
# For top-check stock the three regions are reversed.
# Per-company X/Y offsets allow fine-tuning without code changes.
#
# Alignment test mode (voided: :alignment_test) renders labeled boxes with
# no real data so operators can calibrate on plain paper before using stock.
#
# Usage:
#   gen = CheckGenerator.new(payroll_item)
#   pdf_data = gen.generate          # normal check
#   pdf_data = gen.generate_voided   # VOID watermark on check face
#   pdf_data = gen.alignment_test    # calibration page
#
class CheckGenerator
  # -----------------------------------------------------------------------
  # Layout constants - all in PDF points (72 pts = 1 inch)
  # Letter page: 612 x 792 pts (8.5" x 11")
  # -----------------------------------------------------------------------
  PAGE_WIDTH    = 612.0
  PAGE_HEIGHT   = 792.0
  MARGIN        = 0.0   # We position everything absolutely

  # Each of the three equal sections is 1/3 of the page
  SECTION_HEIGHT = PAGE_HEIGHT / 3.0   # ~ 264 pts (3.667")

  # For bottom-check stock:
  #   Section 0 (y from PAGE_HEIGHT to PAGE_HEIGHT-SECTION_HEIGHT) = employee stub
  #   Section 1 (y from PAGE_HEIGHT-SECTION_HEIGHT to PAGE_HEIGHT-2*SECTION_HEIGHT) = employer stub
  #   Section 2 (y from PAGE_HEIGHT-2*SECTION_HEIGHT to 0) = check face
  STUB_INNER_MARGIN = 20.0
  CHECK_INNER_MARGIN = 18.0

  # Check face field positions relative to bottom of page (for bottom-check)
  # All measurements assume standard top-of-check-section origin.
  # The section top-left for bottom-check is (0, SECTION_HEIGHT) in PDF coords
  # within the bottom section.

  attr_reader :payroll_item, :employee, :pay_period, :company

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee     = payroll_item.employee
    @pay_period   = payroll_item.pay_period
    @company      = pay_period.company
  end

  # Generate a standard check PDF.
  # @return [String] raw PDF binary
  def generate
    render_document(voided: false)
  end

  # Generate a check PDF with VOID watermark (for void records).
  # @return [String] raw PDF binary
  def generate_voided
    render_document(voided: true)
  end

  # Generate an alignment test page with labeled boxes and no real data.
  # @return [String] raw PDF binary
  def alignment_test
    render_alignment_test
  end

  # Suggested filename for storage / download headers.
  def filename
    "check_#{payroll_item.check_number || 'UNASSIGNED'}_#{employee.id}_" \
      "#{pay_period.pay_date.strftime('%Y%m%d')}.pdf"
  end

  private

  # -----------------------------------------------------------------------
  # Offset helpers
  # -----------------------------------------------------------------------

  def offset_x
    (company.check_offset_x.to_f * 72).round(1)   # inches -> points
  end

  def offset_y
    (company.check_offset_y.to_f * 72).round(1)
  end

  def top_check?
    company.check_stock_type == "top_check"
  end

  # -----------------------------------------------------------------------
  # Section origins
  # In Prawn: (0,0) is bottom-left, y increases upward.
  # For bottom-check layout:
  #   Check section:  y origin = 0
  #   Stub 2 (employer): y origin = SECTION_HEIGHT
  #   Stub 1 (employee): y origin = SECTION_HEIGHT * 2
  # For top-check layout the order is reversed.
  # -----------------------------------------------------------------------

  def check_section_y
    top_check? ? (SECTION_HEIGHT * 2) : 0
  end

  def employer_stub_y
    SECTION_HEIGHT
  end

  def employee_stub_y
    top_check? ? 0 : (SECTION_HEIGHT * 2)
  end

  # -----------------------------------------------------------------------
  # Main render
  # -----------------------------------------------------------------------

  def render_document(voided: false)
    Prawn::Document.new(
      page_size:    [ PAGE_WIDTH, PAGE_HEIGHT ],
      page_layout:  :portrait,
      margin:       MARGIN
    ) do |pdf|
      # Draw perforated section dividers
      draw_perforations(pdf)

      # Stub 1 - employee copy
      draw_stub(pdf, section_bottom: employee_stub_y, label: "Employee Copy - Keep for Your Records")

      # Stub 2 - employer copy
      draw_stub(pdf, section_bottom: employer_stub_y, label: "Employer Copy")

      # Check face
      draw_check_face(pdf, section_bottom: check_section_y, voided: voided)
    end.render
  end

  # -----------------------------------------------------------------------
  # Perforated divider lines
  # -----------------------------------------------------------------------

  def draw_perforations(pdf)
    pdf.save_graphics_state do
      pdf.stroke_color "AAAAAA"
      pdf.line_width 0.5
      pdf.dash(3, space: 3)

      [ SECTION_HEIGHT, SECTION_HEIGHT * 2 ].each do |y|
        pdf.stroke_line [ 0, y ], [ PAGE_WIDTH, y ]
      end

      pdf.undash
    end
  end

  # -----------------------------------------------------------------------
  # Stub section
  # -----------------------------------------------------------------------

  def draw_stub(pdf, section_bottom:, label:)
    m   = STUB_INNER_MARGIN
    ox  = offset_x
    oy  = offset_y
    top = section_bottom + SECTION_HEIGHT  # top of this section (PDF y coords)

    # Place text using absolute bounding boxes anchored to section top-left
    # Prawn bounding_box top-left = [x, y_from_bottom]

    # --- Section label (tiny, centered) ---
    pdf.bounding_box([ m + ox, top - 6 + oy ], width: PAGE_WIDTH - m * 2) do
      pdf.font_size(6) { pdf.text label.upcase, color: "999999", align: :center }
    end

    # --- Company header ---
    pdf.bounding_box([ m + ox, top - 16 + oy ], width: 250) do
      pdf.font_size(9) { pdf.text company.name, style: :bold }
      if company.address_line1.present?
        pdf.font_size(7) do
          pdf.text company.address_line1, color: "555555"
          pdf.text "#{company.city}, #{company.state} #{company.zip}", color: "555555"
        end
      end
    end

    # --- Employee + Pay Period info (right side header) ---
    pdf.bounding_box([ PAGE_WIDTH / 2 + ox, top - 16 + oy ], width: PAGE_WIDTH / 2 - m) do
      pdf.font_size(8) do
        pdf.text "Pay Date: #{format_date(pay_period.pay_date)}", align: :right
        pdf.text "Period: #{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}", align: :right
        pdf.text "Employee: #{employee.full_name}", align: :right
        pdf.text "Check #: #{payroll_item.check_number || 'N/A'}", align: :right, style: :bold
      end
    end

    # Separator line
    stub_content_top = top - 54 + oy
    pdf.stroke_color "CCCCCC"
    pdf.line_width 0.3
    pdf.stroke_line [ m + ox, stub_content_top ], [ PAGE_WIDTH - m + ox, stub_content_top ]

    # --- Earnings table ---
    draw_stub_earnings(pdf, x: m + ox, y: stub_content_top - 4, section_bottom: section_bottom, oy: oy)
  end

  def draw_stub_earnings(pdf, x:, y:, section_bottom:, oy:)
    available_height = y - section_bottom - 10

    # Build earnings rows
    rows = []
    if payroll_item.hourly?
      rows << [ "Regular", fmt_hrs(payroll_item.hours_worked), fmt_cur(payroll_item.pay_rate),
                fmt_cur((payroll_item.hours_worked.to_f * payroll_item.pay_rate)) ]
      if payroll_item.overtime_hours.to_f > 0
        rows << [ "Overtime (1.5x)", fmt_hrs(payroll_item.overtime_hours),
                  fmt_cur(payroll_item.pay_rate * 1.5),
                  fmt_cur(payroll_item.overtime_hours.to_f * payroll_item.pay_rate * 1.5) ]
      end
      if payroll_item.holiday_hours.to_f > 0
        rows << [ "Holiday", fmt_hrs(payroll_item.holiday_hours), fmt_cur(payroll_item.pay_rate),
                  fmt_cur(payroll_item.holiday_hours.to_f * payroll_item.pay_rate) ]
      end
      if payroll_item.pto_hours.to_f > 0
        rows << [ "PTO", fmt_hrs(payroll_item.pto_hours), fmt_cur(payroll_item.pay_rate),
                  fmt_cur(payroll_item.pto_hours.to_f * payroll_item.pay_rate) ]
      end
    else
      rows << [ "Salary", "N/A", "#{fmt_cur(payroll_item.pay_rate)}/yr",
                fmt_cur(payroll_item.gross_pay.to_f - payroll_item.bonus.to_f - payroll_item.reported_tips.to_f) ]
    end
    rows << [ "Bonus", "N/A", "N/A", fmt_cur(payroll_item.bonus) ] if payroll_item.bonus.to_f > 0
    rows << [ "Reported Tips", "N/A", "N/A", fmt_cur(payroll_item.reported_tips) ] if payroll_item.reported_tips.to_f > 0

    # Build deductions rows
    deduct_rows = []
    deduct_rows << [ "Guam Income Tax",   fmt_cur(payroll_item.withholding_tax) ]
    deduct_rows << [ "Social Security",   fmt_cur(payroll_item.social_security_tax) ]
    deduct_rows << [ "Medicare",          fmt_cur(payroll_item.medicare_tax) ]
    deduct_rows << [ "Additional W/H",    fmt_cur(payroll_item.additional_withholding) ] if payroll_item.additional_withholding.to_f > 0
    deduct_rows << [ "401(k)",            fmt_cur(payroll_item.retirement_payment) ] if payroll_item.retirement_payment.to_f > 0
    deduct_rows << [ "Roth 401(k)",       fmt_cur(payroll_item.roth_retirement_payment) ] if payroll_item.roth_retirement_payment.to_f > 0
    deduct_rows << [ "Health Insurance",  fmt_cur(payroll_item.insurance_payment) ] if payroll_item.insurance_payment.to_f > 0
    deduct_rows << [ "Loan Repayment",    fmt_cur(payroll_item.loan_payment) ] if payroll_item.loan_payment.to_f > 0

    table_width = (PAGE_WIDTH - STUB_INNER_MARGIN * 2) / 2 - 6

    # Left table: Earnings
    begin
      earn_data = [ [ { content: "EARNINGS", font_style: :bold, colspan: 4 } ] ] +
        rows +
        [ [ { content: "GROSS PAY", font_style: :bold }, "", "",
            { content: fmt_cur(payroll_item.gross_pay), font_style: :bold } ] ]

      col_widths = [ table_width * 0.42, table_width * 0.16, table_width * 0.20, table_width * 0.22 ]

      pdf.bounding_box([ x, y ], width: table_width, height: available_height) do
        pdf.font_size(7) do
          pdf.table(earn_data, column_widths: col_widths, cell_style: { padding: [ 2, 3 ], borders: [ :bottom ], border_color: "EEEEEE" }) do
            row(0).background_color = "F0F0F0"
            row(0).borders = [ :bottom ]
            columns(1..3).align = :right
            row(-1).background_color = "E8F5E9"
          end
        end
      end
    rescue Prawn::Errors::CannotFit
      # Gracefully skip table if not enough space
    end

    # Right table: Deductions + Net Pay
    begin
      right_x = x + table_width + 12
      deduct_data = [ [ { content: "DEDUCTIONS", font_style: :bold, colspan: 2 } ] ] +
        deduct_rows +
        [ [ { content: "TOTAL DEDUCTIONS", font_style: :bold }, { content: fmt_cur(payroll_item.total_deductions), font_style: :bold } ] ] +
        [ [ { content: "NET PAY", font_style: :bold, background_color: "E8F5E9" },
            { content: fmt_cur(payroll_item.net_pay), font_style: :bold, background_color: "E8F5E9" } ] ]

      dcol_widths = [ table_width * 0.62, table_width * 0.38 ]

      pdf.bounding_box([ right_x, y ], width: table_width, height: available_height) do
        pdf.font_size(7) do
          pdf.table(deduct_data, column_widths: dcol_widths, cell_style: { padding: [ 2, 3 ], borders: [ :bottom ], border_color: "EEEEEE" }) do
            row(0).background_color = "F0F0F0"
            row(0).borders = [ :bottom ]
            column(1).align = :right
          end
        end
      end
    rescue Prawn::Errors::CannotFit
      # Gracefully skip
    end
  end

  # -----------------------------------------------------------------------
  # Check face
  # -----------------------------------------------------------------------

  def draw_check_face(pdf, section_bottom:, voided: false)
    m   = CHECK_INNER_MARGIN
    ox  = offset_x
    oy  = offset_y

    # Absolute top of check section in PDF coords
    section_top = section_bottom + SECTION_HEIGHT

    # VOID watermark - drawn first so content overlays it
    if voided
      draw_void_watermark(pdf, section_bottom: section_bottom, section_top: section_top)
    end

    # ---- Company name & address (top-left of check face) ----
    pdf.bounding_box([ m + ox, section_top - 12 + oy ], width: 220) do
      pdf.font_size(9) { pdf.text company.name, style: :bold }
      if company.address_line1.present?
        pdf.font_size(7.5) do
          pdf.text company.address_line1, color: "333333"
          pdf.text "#{company.city}, #{company.state} #{company.zip}", color: "333333"
          pdf.text company.phone if company.phone.present?
        end
      end
    end

    # ---- Check number (top-right) ----
    pdf.bounding_box([ PAGE_WIDTH - 150 + ox, section_top - 12 + oy ], width: 132) do
      pdf.font_size(9) do
        pdf.text "Check No: #{payroll_item.check_number || 'UNASSIGNED'}", align: :right, style: :bold
      end
    end

    # ---- Date (right side, below check number) ----
    pdf.bounding_box([ PAGE_WIDTH - 150 + ox, section_top - 30 + oy ], width: 132) do
      pdf.font_size(8.5) do
        pdf.text "Date: #{format_date(pay_period.pay_date)}", align: :right
      end
    end

    # ---- Horizontal rule below company info ----
    rule_y = section_top - 52 + oy
    pdf.stroke_color "BBBBBB"
    pdf.line_width 0.5
    pdf.stroke_line [ m + ox, rule_y ], [ PAGE_WIDTH - m + ox, rule_y ]

    # ---- "Pay to the order of" line ----
    payee_label_y = rule_y - 18
    pdf.bounding_box([ m + ox, payee_label_y ], width: 300) do
      pdf.font_size(7.5) { pdf.text "Pay to the order of:", color: "666666" }
      pdf.font_size(10) { pdf.text employee.full_name, style: :bold }
    end

    # ---- Numeric dollar amount box (right side) ----
    amount_box_x = PAGE_WIDTH - 140 + ox
    amount_box_y = payee_label_y
    pdf.bounding_box([ amount_box_x, amount_box_y ], width: 122) do
      pdf.font_size(7.5) { pdf.text "Amount", color: "666666", align: :right }
      pdf.font_size(12) do
        pdf.text "$ #{fmt_cur_no_dollar(payroll_item.net_pay)}", align: :right, style: :bold
      end
    end
    # Draw box border
    pdf.stroke_color "888888"
    pdf.line_width 0.6
    pdf.stroke_rectangle [ amount_box_x - 4, amount_box_y + 2 ], 126, 32

    # ---- Amount in words ----
    words_y = payee_label_y - 36
    words_text = NumberToWords.convert(payroll_item.net_pay.to_f)
    pdf.bounding_box([ m + ox, words_y ], width: PAGE_WIDTH - m * 2 - 10) do
      pdf.font_size(9) { pdf.text "#{words_text} *** DOLLARS" }
    end
    # Underline the words line
    pdf.stroke_color "333333"
    pdf.line_width 0.4
    pdf.stroke_line [ m + ox, words_y - 12 ], [ PAGE_WIDTH - m + ox, words_y - 12 ]

    # ---- Bank info ----
    bank_y = words_y - 22
    if company.bank_name.present?
      pdf.bounding_box([ m + ox, bank_y ], width: 240) do
        pdf.font_size(8) { pdf.text company.bank_name, style: :bold }
        pdf.font_size(7) { pdf.text company.bank_address if company.bank_address.present? }
      end
    end

    # ---- Memo line ----
    memo_y = section_bottom + 42 + oy
    pdf.bounding_box([ m + ox, memo_y ], width: 260) do
      pdf.font_size(7) { pdf.text "Memo:", color: "666666" }
      pdf.font_size(7.5) do
        pdf.text "Payroll #{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"
      end
    end

    # ---- Signature line (bottom-right) ----
    sig_x = PAGE_WIDTH / 2 + 20 + ox
    sig_y = section_bottom + 40 + oy
    sig_width = PAGE_WIDTH / 2 - m - 20
    pdf.stroke_color "333333"
    pdf.line_width 0.5
    pdf.stroke_line [ sig_x, sig_y ], [ sig_x + sig_width, sig_y ]
    pdf.bounding_box([ sig_x, sig_y - 2 ], width: sig_width) do
      pdf.font_size(7) { pdf.text "Authorized Signature", align: :center, color: "666666" }
    end

    # ---- Bottom "VOID if not cashed within 90 days" notice ----
    pdf.bounding_box([ m + ox, section_bottom + 14 + oy ], width: PAGE_WIDTH - m * 2) do
      pdf.font_size(6) do
        pdf.text "VOID after 90 days. This check is negotiable only for the payee named above.", color: "999999", align: :center
      end
    end
  end

  def draw_void_watermark(pdf, section_bottom:, section_top:)
    center_x = PAGE_WIDTH / 2
    center_y = section_bottom + SECTION_HEIGHT / 2

    pdf.save_graphics_state do
      pdf.fill_color "FFCCCC"
      pdf.transparent(0.25) do
        pdf.font_size(90) do
          pdf.rotate(30, origin: [ center_x, center_y ]) do
            pdf.draw_text "VOID", at: [ center_x - 140, center_y - 30 ], style: :bold
          end
        end
      end
    end
    pdf.fill_color "000000"  # reset
  end

  # -----------------------------------------------------------------------
  # Alignment test page
  # -----------------------------------------------------------------------

  def render_alignment_test
    Prawn::Document.new(
      page_size:   [ PAGE_WIDTH, PAGE_HEIGHT ],
      page_layout: :portrait,
      margin:      MARGIN
    ) do |pdf|
      draw_perforations(pdf)

      # Annotate each section with labeled boxes
      [ [ employee_stub_y, "STUB 1 - Employee Copy" ],
        [ employer_stub_y, "STUB 2 - Employer Copy" ],
        [ check_section_y, "CHECK FACE" ] ].each do |sect_bottom, sect_label|
        sect_top = sect_bottom + SECTION_HEIGHT
        m = STUB_INNER_MARGIN
        ox = offset_x
        oy = offset_y

        # Section bounding box
        pdf.stroke_color "0000FF"
        pdf.line_width 0.5
        pdf.stroke_rectangle [ m + ox, sect_top - 4 + oy ], PAGE_WIDTH - m * 2, SECTION_HEIGHT - 8

        # Section label
        pdf.bounding_box([ m + 4 + ox, sect_top - 8 + oy ], width: PAGE_WIDTH - m * 2 - 8) do
          pdf.font_size(10) { pdf.text sect_label, style: :bold, color: "0000AA", align: :center }
        end

        if sect_label.include?("CHECK")
          # Draw labeled field boxes on check face
          alignment_check_fields(pdf, sect_bottom: sect_bottom, sect_top: sect_top, ox: ox, oy: oy)
        else
          pdf.bounding_box([ m + 4 + ox, sect_top - 40 + oy ], width: PAGE_WIDTH - m * 2 - 8) do
            pdf.font_size(8) { pdf.text "[EARNINGS + DEDUCTIONS TABLE]", color: "555555", align: :center }
          end
        end
      end

      # Page title
      pdf.bounding_box([ 0, PAGE_HEIGHT - 4 ], width: PAGE_WIDTH) do
        pdf.font_size(7) do
          pdf.text "ALIGNMENT TEST - Print on plain paper. Hold against check stock to verify field positions.",
            align: :center, color: "CC0000"
        end
      end
    end.render
  end

  def alignment_check_fields(pdf, sect_bottom:, sect_top:, ox:, oy:)
    field_specs = [
      { label: "COMPANY NAME/ADDRESS",  x: 18,  y: sect_top - 12, w: 220, h: 40 },
      { label: "CHECK NUMBER",          x: PAGE_WIDTH - 146, y: sect_top - 12, w: 128, h: 16 },
      { label: "DATE",                  x: PAGE_WIDTH - 146, y: sect_top - 30, w: 128, h: 16 },
      { label: "PAY TO THE ORDER OF (Payee Name)", x: 18, y: sect_top - 70, w: 300, h: 30 },
      { label: "$ AMOUNT BOX",          x: PAGE_WIDTH - 140, y: sect_top - 70, w: 122, h: 32 },
      { label: "AMOUNT IN WORDS ----- DOLLARS", x: 18, y: sect_top - 106, w: PAGE_WIDTH - 36, h: 20 },
      { label: "MEMO LINE",             x: 18,  y: sect_bottom + 42, w: 260, h: 28 },
      { label: "AUTHORIZED SIGNATURE LINE", x: PAGE_WIDTH / 2 + 20, y: sect_bottom + 40, w: 200, h: 24 },
    ]

    field_specs.each do |f|
      fx = f[:x] + ox
      fy = f[:y] + oy
      pdf.stroke_color "FF0000"
      pdf.line_width 0.5
      pdf.stroke_rectangle [ fx, fy ], f[:w], f[:h]
      pdf.bounding_box([ fx + 2, fy - 2 ], width: f[:w] - 4) do
        pdf.font_size(6) { pdf.text f[:label], color: "CC0000" }
      end
    end
  end

  # -----------------------------------------------------------------------
  # Formatting helpers
  # -----------------------------------------------------------------------

  def fmt_cur(amount)
    return "$0.00" if amount.nil?
    "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', amount.to_f))}"
  end

  def fmt_cur_no_dollar(amount)
    return "0.00" if amount.nil?
    ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', amount.to_f))
  end

  def fmt_hrs(hours)
    return "0.00" if hours.nil?
    format("%.2f", hours.to_f)
  end

  def format_date(date)
    date.strftime("%m/%d/%Y")
  end
end
