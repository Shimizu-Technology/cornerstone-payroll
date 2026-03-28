# frozen_string_literal: true

require "prawn"
require "prawn/table"
require "active_support/number_helper"
require_relative "../../lib/number_to_words"

# Generates a 3-part letter-size PDF matching Cornerstone's check format.
#
# Layout (top-check, Cornerstone default):
#   Top section    : Check face (payee, date, amount, pay period)
#   Middle section : Stub 1 (4-quadrant earnings/taxes/deductions with YTD)
#   Bottom section : Stub 2 (duplicate of stub 1)
#
# Stub 4-quadrant layout:
#   ┌────────────────────────────────┬──────────────────────────┐
#   │ Employee Name  PAY H R Cur YTD │ TAXES        Current YTD │
#   ├────────────────────────────────┤──────────────────────────┤
#   │ Company        OTHER PAY C YTD │ DEDUCTIONS   Current YTD │
#   ├────────────────────────────────┤──────────────────────────┤
#   │ Period / Date / BENEFITS/MEMO  │ ┌SUMMARY    Cur    YTD┐ │
#   │                                │ │NET PAY:    $xxx.xx  │ │
#   │                                │ └─────────────────────┘ │
#   └────────────────────────────────┴──────────────────────────┘
#
class CheckGenerator
  PAGE_WIDTH     = 612.0
  PAGE_HEIGHT    = 792.0
  MARGIN         = 0.0
  SECTION_HEIGHT = PAGE_HEIGHT / 3.0  # ~264 pts / 3.667"
  M              = 16.0               # inner margin for all sections
  DEFAULT_LAYOUT = {
    check_face: {
      date:         { x: 474.0, y: 242.0, width: 112.0, font_size: 10.0 },
      payee:        { x: 42.0,  y: 192.0, width: 320.0, font_size: 10.0 },
      amount:       { x: 467.0, y: 192.0, width: 120.0, font_size: 10.0 },
      amount_words: { x: 52.0,  y: 158.0, width: 492.0, font_size: 9.0 },
      pay_period:   { x: 42.0,  y: 76.0,  width: 360.0, font_size: 9.0 },
      memo:         { x: 22.0,  y: 30.0,  width: 260.0, font_size: 7.5 },
      signature:    { x: 322.0, y: 22.0,  width: 246.0 }
    },
    stub: {
      left: 16.0,
      right: 16.0,
      y: 0.0,
      left_ratio: 0.56,
      row1_y: 258.0,
      row2_y: 164.0,
      row3_y: 80.0,
      pay_table_y_offset: -12.0,
      other_pay_x_offset: 100.0,
      other_pay_y_offset: -12.0,
      benefits_x_ratio: 0.42,
      memo_y_offset: -48.0,
      summary_x_offset: 0.0,
      summary_y_offset: 0.0,
      table_height: 82.0,
      table_padding_y: 1.5,
      table_padding_x: 3.0,
      summary_box_h: 76.0,
      summary_padding_y: 2.0,
      summary_padding_x: 2.0
    }
  }.freeze

  attr_reader :payroll_item, :employee, :pay_period, :company

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee     = payroll_item.employee
    @pay_period   = payroll_item.pay_period
    @company      = pay_period.company
  end

  def generate
    render_document(voided: false)
  end

  def generate_voided
    render_document(voided: true)
  end

  def alignment_test
    render_alignment_test
  end

  def filename
    pay_date_token = pay_period.pay_date&.strftime("%Y%m%d") || "undated"
    "check_#{payroll_item.check_number || 'UNASSIGNED'}_#{employee.id}_#{pay_date_token}.pdf"
  end

  private

  # -----------------------------------------------------------------------
  # Offsets & section y-origins
  # -----------------------------------------------------------------------
  def ox; (company.check_offset_x.to_f * 72).round(1); end
  def oy; (company.check_offset_y.to_f * 72).round(1); end

  def top_check?
    company.check_stock_type != "bottom_check"
  end

  def check_y;  top_check? ? (SECTION_HEIGHT * 2) : 0;              end
  def stub1_y;  top_check? ? SECTION_HEIGHT       : (SECTION_HEIGHT * 2); end
  def stub2_y;  top_check? ? 0                    : SECTION_HEIGHT;  end

  # -----------------------------------------------------------------------
  # YTD data
  # -----------------------------------------------------------------------
  def ytd
    @ytd ||= begin
      year = pay_period.pay_date&.year || Date.current.year
      items = PayrollItem.joins(:pay_period)
        .where(employee_id: employee.id)
        .where(pay_periods: { status: "committed", company_id: company.id })
        .where("EXTRACT(YEAR FROM pay_periods.pay_date) = ?", year)

      gross   = items.sum(:gross_pay).to_f
      fit     = items.sum(:withholding_tax).to_f
      ss      = items.sum(:social_security_tax).to_f
      med     = items.sum(:medicare_tax).to_f
      addl_wh = items.sum(:additional_withholding).to_f
      retire  = items.sum(:retirement_payment).to_f
      roth    = items.sum(:roth_retirement_payment).to_f
      ins     = items.sum(:insurance_payment).to_f
      loan    = items.sum(:loan_payment).to_f

      taxes = fit + ss + med + addl_wh
      deds  = retire + roth + ins + loan

      { gross: gross, fit: fit, ss: ss, med: med, addl_wh: addl_wh,
        retire: retire, roth: roth, ins: ins, loan: loan,
        taxes: taxes, deds: deds, net: items.sum(:net_pay).to_f }
    end
  end

  def cur_taxes
    payroll_item.withholding_tax.to_f + payroll_item.social_security_tax.to_f +
      payroll_item.medicare_tax.to_f + payroll_item.additional_withholding.to_f
  end

  def cur_deds
    payroll_item.retirement_payment.to_f + payroll_item.roth_retirement_payment.to_f +
      payroll_item.insurance_payment.to_f + payroll_item.loan_payment.to_f
  end

  # -----------------------------------------------------------------------
  # Main render
  # -----------------------------------------------------------------------
  def render_document(voided: false)
    Prawn::Document.new(
      page_size: [PAGE_WIDTH, PAGE_HEIGHT], page_layout: :portrait, margin: MARGIN
    ) do |pdf|
      draw_perforations(pdf)
      draw_check_face(pdf, check_y, voided)
      draw_stub(pdf, stub1_y, voided)
      draw_stub(pdf, stub2_y, voided)
    end.render
  end

  # -----------------------------------------------------------------------
  # Perforations
  # -----------------------------------------------------------------------
  def draw_perforations(_pdf)
    # The actual physical stock already contains the tear lines/perforations.
    # Drawing them in the PDF makes the preview noisier and interferes with
    # printing on pre-filled check stock, so leave them out.
  end

  # -----------------------------------------------------------------------
  # CHECK FACE  – positioned for QuickBooks-style stock overlay
  # -----------------------------------------------------------------------
  def draw_check_face(pdf, sect_bot, voided)
    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided
    date_cfg = layout_field(:check_face, :date)
    payee_cfg = layout_field(:check_face, :payee)
    amount_cfg = layout_field(:check_face, :amount)
    words_cfg = layout_field(:check_face, :amount_words)
    period_cfg = layout_field(:check_face, :pay_period)
    memo_cfg = layout_field(:check_face, :memo)
    signature_cfg = layout_field(:check_face, :signature)

    # ---- Date (top-right) ----
    pdf.bounding_box([date_cfg["x"].to_f + ox, sect_bot + date_cfg["y"].to_f + oy], width: date_cfg["width"].to_f) do
      pdf.font_size(date_cfg["font_size"].to_f) { pdf.text format_date(pay_period.pay_date), align: :right }
    end

    # ---- Payee name (left) + amount (right) ----
    pdf.bounding_box([payee_cfg["x"].to_f + ox, sect_bot + payee_cfg["y"].to_f + oy], width: payee_cfg["width"].to_f) do
      pdf.font_size(payee_cfg["font_size"].to_f) { pdf.text employee.full_name }
    end
    pdf.bounding_box([amount_cfg["x"].to_f + ox, sect_bot + amount_cfg["y"].to_f + oy], width: amount_cfg["width"].to_f) do
      pdf.font_size(amount_cfg["font_size"].to_f) { pdf.text "**#{fn(payroll_item.net_pay)}", align: :right }
    end

    # ---- Amount in words ----
    pdf.bounding_box([words_cfg["x"].to_f + ox, sect_bot + words_cfg["y"].to_f + oy], width: words_cfg["width"].to_f) do
      pdf.font_size(words_cfg["font_size"].to_f) { pdf.text "*****#{NumberToWords.convert(payroll_item.net_pay)}" }
    end

    # ---- Pay Period ----
    pdf.bounding_box([period_cfg["x"].to_f + ox, sect_bot + period_cfg["y"].to_f + oy], width: period_cfg["width"].to_f) do
      pdf.font_size(period_cfg["font_size"].to_f) do
        pdf.text "Pay Period:  #{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"
      end
    end

    # ---- Memo + Signature (bottom of check stock face) ----
    pdf.bounding_box([memo_cfg["x"].to_f + ox, sect_bot + memo_cfg["y"].to_f + oy], width: memo_cfg["width"].to_f) do
      pdf.font_size(7) { pdf.text "Memo:" }
      pdf.font_size(memo_cfg["font_size"].to_f) { pdf.text "Payroll #{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}" }
    end

    sig_x = signature_cfg["x"].to_f + ox
    sig_y = sect_bot + signature_cfg["y"].to_f + oy
    sig_w = signature_cfg["width"].to_f
    pdf.stroke_color "333333"; pdf.line_width 0.5
    pdf.stroke_line [sig_x, sig_y], [sig_x + sig_w, sig_y]
  end

  # -----------------------------------------------------------------------
  # STUB – Cornerstone 4-quadrant layout
  # -----------------------------------------------------------------------
  def draw_stub(pdf, sect_bot, voided)
    stub_cfg = layout_section(:stub)
    usable = PAGE_WIDTH - stub_cfg["left"].to_f - stub_cfg["right"].to_f
    left_w = usable * stub_cfg["left_ratio"].to_f
    right_w = usable - left_w
    lx = stub_cfg["left"].to_f + ox
    rx = lx + left_w
    sy = stub_cfg["y"].to_f + oy

    # Row heights (approximate, content-driven)
    row1_top = sect_bot + stub_cfg["row1_y"].to_f + sy
    row2_top = sect_bot + stub_cfg["row2_y"].to_f + sy
    row3_top = sect_bot + stub_cfg["row3_y"].to_f + sy

    # ================================================================
    # ROW 1:  PAY (left)  |  TAXES (right)
    # ================================================================
    # Employee name on same line as PAY header
    pdf.font_size(8) do
      pdf.draw_text employee.full_name, at: [lx, row1_top], style: :bold
    end

    draw_section_table(pdf,
      x: lx, y: row1_top + stub_cfg["pay_table_y_offset"].to_f, w: left_w - 8,
      title: "PAY",
      columns: %w[Hours Rate Current YTD],
      col_ratios: [0.28, 0.14, 0.14, 0.22, 0.22],
      rows: pay_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    draw_section_table(pdf,
      x: rx, y: row1_top, w: right_w,
      title: "TAXES",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: tax_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    # ================================================================
    # ROW 2:  Company + OTHER PAY (left)  |  DEDUCTIONS (right)
    # ================================================================
    pdf.font_size(8) do
      pdf.draw_text company.name, at: [lx, row2_top], style: :bold
    end

    draw_section_table(pdf,
      x: lx + stub_cfg["other_pay_x_offset"].to_f,
      y: row2_top + stub_cfg["other_pay_y_offset"].to_f,
      w: left_w - (stub_cfg["other_pay_x_offset"].to_f + 8),
      title: "OTHER PAY",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: other_pay_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    draw_section_table(pdf,
      x: rx, y: row2_top, w: right_w,
      title: "DEDUCTIONS",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: deduction_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    # ================================================================
    # ROW 3:  Period/Date/Benefits/Memo (left)  |  SUMMARY (right)
    # ================================================================
    pdf.bounding_box([lx, row3_top], width: left_w * stub_cfg["benefits_x_ratio"].to_f) do
      pdf.font_size(7.5) do
        pdf.text "Pay Period", style: :bold
        pdf.text "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"
        pdf.move_down 4
        pdf.text "Pay Date", style: :bold
        pdf.text format_date(pay_period.pay_date)
      end
    end

    # BENEFITS header (empty but present for format compatibility)
    benefits_x = lx + left_w * stub_cfg["benefits_x_ratio"].to_f
    benefits_w = left_w * (1 - stub_cfg["benefits_x_ratio"].to_f) - 8
    pdf.bounding_box([benefits_x, row3_top], width: benefits_w) do
      pdf.font_size(7) do
        benefits_data = [
          [
            { content: "BENEFITS", font_style: :bold },
            { content: "Used", font_style: :bold, align: :right },
            { content: "Available", font_style: :bold, align: :right }
          ]
        ]
        bw = benefits_w
        pdf.table(benefits_data,
          column_widths: [bw * 0.46, bw * 0.27, bw * 0.27],
          cell_style: { padding: [1.5, 3], borders: [:bottom], border_color: "999999", size: 7 }
        ) do
          row(0).background_color = "EEEEEE"
        end
      rescue Prawn::Errors::CannotFit
        # skip
      end
    end

    # MEMO label
    pdf.bounding_box([lx, row3_top + stub_cfg["memo_y_offset"].to_f], width: left_w) do
      pdf.font_size(7.5) { pdf.text "MEMO:", style: :bold }
    end

    # SUMMARY box (bordered)
    draw_summary_box(
      pdf,
      x: rx + stub_cfg["summary_x_offset"].to_f,
      y: row3_top + stub_cfg["summary_y_offset"].to_f,
      w: right_w,
      stub_cfg: stub_cfg
    )

    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided
  end

  # -----------------------------------------------------------------------
  # Section table helper
  # -----------------------------------------------------------------------
  def draw_section_table(pdf, x:, y:, w:, title:, columns:, col_ratios:, rows:, table_height:, padding_y:, padding_x:)
    header = [{ content: title, font_style: :bold }] +
      columns.map { |c| { content: c, font_style: :bold, align: :right } }

    data = [header] + rows
    col_widths = col_ratios.map { |r| w * r }

    pdf.bounding_box([x, y], width: w, height: table_height) do
      pdf.font_size(7) do
        pdf.table(data, column_widths: col_widths, cell_style: {
          padding: [padding_y, padding_x], borders: [], size: 7
        }) do
          row(0).borders = [:bottom]
          row(0).border_color = "999999"
          row(0).background_color = "EEEEEE"
          columns(1..-1).align = :right
        end
      end
    end
  rescue Prawn::Errors::CannotFit
    pdf.bounding_box([x, y], width: w, height: 20) do
      pdf.font_size(6) { pdf.text "[TABLE]", color: "CC0000" }
    end
  end

  # -----------------------------------------------------------------------
  # Data row builders
  # -----------------------------------------------------------------------
  def pay_rows
    rows = []
    is_c = employee.contractor?
    earnings = payroll_item.payroll_item_earnings.to_a

    if is_c
      if employee.contractor_hourly?
        hourly_earnings = earnings.select { |earning| %w[regular overtime holiday pto].include?(earning.category) }
        if hourly_earnings.any?
          hourly_earnings.each do |earning|
            rows << [earning.label, fh(earning.hours), fn(earning.rate), fn(earning.amount), fn(earning.amount)]
          end
        else
          rp = payroll_item.hours_worked.to_f * payroll_item.pay_rate.to_f
          rows << [label_or("Contract Labor"), fh(payroll_item.hours_worked), fn(payroll_item.pay_rate), fn(rp), fn(ytd[:gross])]
          if payroll_item.overtime_hours.to_f > 0
            ot_r = payroll_item.pay_rate.to_f * 1.5
            ot_p = payroll_item.overtime_hours.to_f * ot_r
            rows << ["Contract OT", fh(payroll_item.overtime_hours), fn(ot_r), fn(ot_p), fn(ot_p)]
          end
        end
      else
        rows << [label_or("Contract Fee"), "-", "-", fn(payroll_item.gross_pay.to_f - payroll_item.bonus.to_f), fn(ytd[:gross])]
      end
    elsif payroll_item.hourly?
      hourly_earnings = earnings.select { |earning| %w[regular overtime holiday pto].include?(earning.category) }
      if hourly_earnings.any?
        hourly_earnings.each do |earning|
          rows << [earning.label, fh(earning.hours), fn(earning.rate), fn(earning.amount), fn(earning.amount)]
        end
      else
        dept = employee.department&.name || "Regular"
        reg = payroll_item.hours_worked.to_f * payroll_item.pay_rate.to_f
        rows << [dept, fh(payroll_item.hours_worked), fn(payroll_item.pay_rate), fn(reg), fn(ytd[:gross])]
        if payroll_item.overtime_hours.to_f > 0
          otr = payroll_item.pay_rate.to_f * 1.5
          rows << ["Overtime Pay", "-", fn(otr), fn(payroll_item.overtime_hours.to_f * otr), fn(payroll_item.overtime_hours.to_f * otr)]
        end
        if payroll_item.holiday_hours.to_f > 0
          rows << ["Holiday", fh(payroll_item.holiday_hours), fn(payroll_item.pay_rate), fn(payroll_item.holiday_hours.to_f * payroll_item.pay_rate.to_f), "-"]
        end
        if payroll_item.pto_hours.to_f > 0
          rows << ["PTO", fh(payroll_item.pto_hours), fn(payroll_item.pay_rate), fn(payroll_item.pto_hours.to_f * payroll_item.pay_rate.to_f), "-"]
        end
      end
    else
      sal_label = "Salary"
      sal_label = "Salary - #{employee.first_name&.first} #{employee.last_name}" if employee.first_name.present?
      sal_cur = payroll_item.gross_pay.to_f - payroll_item.bonus.to_f - payroll_item.reported_tips.to_f
      rows << [sal_label, "-", "-", fn(sal_cur), fn(ytd[:gross])]
    end

    rows << ["Bonus", "-", "-", fn(payroll_item.bonus), fn(payroll_item.bonus)] if payroll_item.bonus.to_f > 0
    rows << ["Paycheck Tips", "-", "-", fn(payroll_item.reported_tips), fn(payroll_item.reported_tips)] if payroll_item.reported_tips.to_f > 0
    rows
  end

  def tax_rows
    return [] if employee.contractor?
    rows = []
    rows << ["Federal Income Tax", fn(payroll_item.withholding_tax), fn(ytd[:fit])]
    rows << ["Social Security", fn(payroll_item.social_security_tax), fn(ytd[:ss])]
    rows << ["Medicare", fn(payroll_item.medicare_tax), fn(ytd[:med])]
    rows << ["Additional W/H", fn(payroll_item.additional_withholding), fn(ytd[:addl_wh])] if payroll_item.additional_withholding.to_f > 0
    rows
  end

  def other_pay_rows
    rows = []
    if payroll_item.retirement_payment.to_f > 0 && employee.respond_to?(:retirement_rate) && employee.retirement_rate.to_f > 0
      rows << ["401(k) Pre-Tax", fn(payroll_item.retirement_payment), fn(ytd[:retire])]
    end
    rows << ["Non-Taxable", fn(payroll_item.non_taxable_pay), "-"] if payroll_item.non_taxable_pay.to_f > 0
    rows
  end

  def deduction_rows
    return [] if employee.contractor?
    rows = []
    rows << ["401(k) Pre-Tax", fn(payroll_item.retirement_payment), fn(ytd[:retire])] if payroll_item.retirement_payment.to_f > 0
    rows << ["Roth 401(k)", fn(payroll_item.roth_retirement_payment), fn(ytd[:roth])] if payroll_item.roth_retirement_payment.to_f > 0
    rows << ["Health Insurance", fn(payroll_item.insurance_payment), fn(ytd[:ins])] if payroll_item.insurance_payment.to_f > 0
    rows << ["Loan", fn(payroll_item.loan_payment), fn(ytd[:loan])] if payroll_item.loan_payment.to_f > 0
    rows
  end

  # -----------------------------------------------------------------------
  # SUMMARY box (bottom-right, bordered like Cornerstone)
  # -----------------------------------------------------------------------
  def draw_summary_box(pdf, x:, y:, w:, stub_cfg:)
    box_h = stub_cfg["summary_box_h"].to_f

    # Draw outer border
    pdf.stroke_color "333333"
    pdf.line_width 0.8
    pdf.stroke_rectangle [x, y], w, box_h

    inner_w = w - 6
    cw = [inner_w * 0.38, inner_w * 0.31, inner_w * 0.31]

    header = [
      { content: "SUMMARY", font_style: :bold },
      { content: "Current", font_style: :bold },
      { content: "YTD", font_style: :bold }
    ]

    data_rows = [
      ["Total Pay", fd(payroll_item.gross_pay), fd(ytd[:gross])],
      ["Taxes", fd(cur_taxes), fd(ytd[:taxes])],
      ["Deductions", fd(cur_deds), fd(ytd[:deds])]
    ]

    net_row = [
      { content: "NET PAY:", font_style: :bold },
      "",
      { content: fd(payroll_item.net_pay), font_style: :bold }
    ]

    data = [header] + data_rows + [net_row]

    pdf.bounding_box([x + 3, y - 3], width: inner_w, height: box_h - 6) do
      pdf.font_size(7) do
        pdf.table(data, column_widths: cw, cell_style: {
          padding: [stub_cfg["summary_padding_y"].to_f, stub_cfg["summary_padding_x"].to_f], borders: [], size: 7
        }) do
          row(0).borders = [:bottom]
          row(0).border_color = "999999"
          row(0).background_color = "EEEEEE"
          columns(1..2).align = :right
          row(-1).borders = [:top]
          row(-1).border_color = "333333"
        end
      rescue Prawn::Errors::CannotFit
        pdf.text "[SUMMARY]", size: 6, color: "CC0000"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Void watermark
  # -----------------------------------------------------------------------
  def draw_void_watermark(pdf, sect_bot, sect_top)
    cx = PAGE_WIDTH / 2
    cy = sect_bot + SECTION_HEIGHT / 2
    pdf.save_graphics_state do
      pdf.fill_color "FFCCCC"
      pdf.transparent(0.25) do
        pdf.font_size(90) do
          pdf.rotate(30, origin: [cx, cy]) do
            pdf.draw_text "VOID", at: [cx - 140, cy - 30], style: :bold
          end
        end
      end
    end
    pdf.fill_color "000000"
  end

  # -----------------------------------------------------------------------
  # Alignment test
  # -----------------------------------------------------------------------
  def render_alignment_test
    Prawn::Document.new(
      page_size: [PAGE_WIDTH, PAGE_HEIGHT], page_layout: :portrait, margin: MARGIN
    ) do |pdf|
      draw_perforations(pdf)
      stub_cfg = layout_section(:stub)
      [[check_y, "CHECK FACE"], [stub1_y, "STUB 1"], [stub2_y, "STUB 2"]].each do |sy, label|
        st = sy + SECTION_HEIGHT
        pdf.stroke_color "0000FF"
        pdf.line_width 0.5
        pdf.stroke_rectangle [M + ox, st - 4 + oy], PAGE_WIDTH - M * 2, SECTION_HEIGHT - 8
        pdf.bounding_box([M + 4 + ox, st - 8 + oy], width: PAGE_WIDTH - M * 2 - 8) do
          pdf.font_size(10) { pdf.text label, style: :bold, color: "0000AA", align: :center }
        end
      end
      %i[date payee amount amount_words pay_period memo signature].each do |field|
        cfg = layout_field(:check_face, field)
        draw_alignment_marker(
          pdf,
          x: cfg["x"].to_f + ox,
          y: check_y + cfg["y"].to_f + oy,
          label: "check.#{field}"
        )
      end
      [stub1_y, stub2_y].each_with_index do |sect_bot, idx|
        %w[row1_y row2_y row3_y].each_with_index do |row_key, row_idx|
          draw_alignment_marker(
            pdf,
            x: stub_cfg["left"].to_f + ox,
            y: sect_bot + stub_cfg[row_key].to_f + stub_cfg["y"].to_f + oy,
            label: "stub#{idx + 1}.row#{row_idx + 1}"
          )
        end
      end
      pdf.bounding_box([0, PAGE_HEIGHT - 4], width: PAGE_WIDTH) do
        pdf.font_size(7) do
          pdf.text "ALIGNMENT TEST – Print on plain paper.", align: :center, color: "CC0000"
        end
      end
    end.render
  end

  # -----------------------------------------------------------------------
  # Formatting helpers
  # -----------------------------------------------------------------------
  def fn(v)  # number without $
    return "0.00" if v.nil?
    ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", v.to_f))
  end

  def fd(v)  # number with $
    "$#{fn(v)}"
  end

  def fmt_nodollar(v)
    fn(v)
  end

  def fh(v)
    return "-" if v.nil? || v.to_f.zero?
    format("%.2f", v.to_f)
  end

  def format_date(d)
    d&.strftime("%m/%d/%Y") || "N/A"
  end

  def label_or(default)
    default
  end

  def layout_section(name)
    layout_config.fetch(name.to_s)
  end

  def layout_field(section, field)
    layout_section(section).fetch(field.to_s)
  end

  def layout_config
    @layout_config ||= deep_merge(stringify_layout(DEFAULT_LAYOUT), stringify_layout(company.check_layout_config || {}))
  end

  def stringify_layout(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), acc| acc[key.to_s] = stringify_layout(nested) }
    when Array
      value.map { |entry| stringify_layout(entry) }
    else
      value
    end
  end

  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, old_value, new_value|
      if old_value.is_a?(Hash) && new_value.is_a?(Hash)
        deep_merge(old_value, new_value)
      else
        new_value
      end
    end
  end

  def draw_alignment_marker(pdf, x:, y:, label:)
    pdf.save_graphics_state do
      pdf.stroke_color "CC0000"
      pdf.fill_color "CC0000"
      pdf.line_width 0.4
      pdf.stroke_line [x - 6, y], [x + 6, y]
      pdf.stroke_line [x, y - 6], [x, y + 6]
      pdf.font_size(6) { pdf.draw_text label, at: [x + 8, y + 2] }
    end
    pdf.fill_color "000000"
    pdf.stroke_color "000000"
  end
end
