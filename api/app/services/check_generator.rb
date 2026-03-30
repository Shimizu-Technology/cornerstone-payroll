# frozen_string_literal: true

require "prawn"
require "prawn/table"
require "active_support/number_helper"
require_relative "../../lib/number_to_words"

# Generates a 3-part letter-size PDF matching QuickBooks-style check stock.
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
#   │ Period / Date / Memo           │ ┌SUMMARY    Cur    YTD┐ │
#   │                                │ │rows only            │ │
#   │                                │ NET PAY:    $xxx.xx    │
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
      date:         { x: 474.0, y: 216.0, width: 112.0, font_size: 10.0 },
      payee:        { x: 64.0,  y: 180.0, width: 320.0, font_size: 10.0 },
      amount:       { x: 467.0, y: 182.0, width: 120.0, font_size: 10.0 },
      amount_words: { x: 52.0,  y: 156.0, width: 492.0, font_size: 9.0 },
      memo:         { x: 22.0,  y: 64.0,  width: 260.0, font_size: 7.5 },
      signature:    { x: 322.0, y: 10.0,  width: 246.0 }
    },
    stub: {
      left: 16.0,
      right: 16.0,
      y: 0.0,
      left_ratio: 0.56,
      row1_y: 252.0,
      row2_y: 176.0,
      row3_y: 118.0,
      pay_table_y_offset: -10.0,
      other_pay_x_offset: 100.0,
      other_pay_y_offset: -10.0,
      memo_y_offset: -36.0,
      summary_x_offset: -18.0,
      summary_y_offset: 0.0,
      table_height: 56.0,
      table_padding_y: 1.0,
      table_padding_x: 2.0,
      summary_box_h: 48.0,
      summary_padding_y: 1.5,
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
  # CHECK FACE  – keep the top third clean like QuickBooks
  # -----------------------------------------------------------------------
  def draw_check_face(pdf, sect_bot, voided)
    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided
    date_cfg = layout_field(:check_face, :date)
    payee_cfg = layout_field(:check_face, :payee)
    amount_cfg = layout_field(:check_face, :amount)
    words_cfg = layout_field(:check_face, :amount_words)
    memo_cfg = layout_field(:check_face, :memo)

    # ---- Date (top-right) ----
    pdf.bounding_box([date_cfg["x"].to_f + ox, sect_bot + date_cfg["y"].to_f + oy], width: date_cfg["width"].to_f) do
      pdf.font_size(date_cfg["font_size"].to_f) { pdf.text format_date(pay_period.pay_date), align: :right }
    end

    # ---- Payee name (left) + amount (right) ----
    pdf.bounding_box([payee_cfg["x"].to_f + ox, sect_bot + payee_cfg["y"].to_f + oy], width: payee_cfg["width"].to_f) do
      pdf.font_size(payee_cfg["font_size"].to_f) { pdf.text employee.full_name }
    end
    pdf.bounding_box([amount_cfg["x"].to_f + ox, sect_bot + amount_cfg["y"].to_f + oy], width: amount_cfg["width"].to_f) do
      pdf.font_size(amount_cfg["font_size"].to_f) { pdf.text fn(payroll_item.net_pay), align: :right }
    end

    # ---- Amount in words ----
    pdf.bounding_box([words_cfg["x"].to_f + ox, sect_bot + words_cfg["y"].to_f + oy], width: words_cfg["width"].to_f) do
      pdf.font_size(words_cfg["font_size"].to_f) { pdf.text NumberToWords.convert(payroll_item.net_pay) }
    end

    # ---- Memo (bottom of check stock face) ----
    pdf.bounding_box([memo_cfg["x"].to_f + ox, sect_bot + memo_cfg["y"].to_f + oy], width: memo_cfg["width"].to_f) do
      pdf.font_size(memo_cfg["font_size"].to_f) do
        pdf.text resolve_memo_text
      end
    end

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
    pdf.font_size(7) do
      pdf.draw_text employee.full_name, at: [lx, row1_top], style: :bold
    end

    table_y1 = row1_top + stub_cfg["pay_table_y_offset"].to_f

    draw_section_table(pdf,
      x: lx, y: table_y1, w: left_w - 8,
      title: "PAY",
      columns: %w[Hours Rate Current YTD],
      col_ratios: [0.28, 0.14, 0.14, 0.22, 0.22],
      rows: pay_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    draw_section_table(pdf,
      x: rx, y: table_y1, w: right_w,
      title: "TAXES",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: tax_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    # ================================================================
    # ROW 2:  OTHER PAY (left)  |  DEDUCTIONS (right)
    # ================================================================
    table_y2 = row2_top

    draw_section_table(pdf,
      x: lx, y: table_y2, w: left_w - 8,
      title: "OTHER PAY",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: other_pay_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    draw_section_table(pdf,
      x: rx, y: table_y2, w: right_w,
      title: "DEDUCTIONS",
      columns: %w[Current YTD],
      col_ratios: [0.46, 0.27, 0.27],
      rows: deduction_rows,
      table_height: stub_cfg["table_height"].to_f,
      padding_y: stub_cfg["table_padding_y"].to_f,
      padding_x: stub_cfg["table_padding_x"].to_f
    )

    # ================================================================
    # ROW 3:  Period/Date/Memo (left)  |  SUMMARY (right)
    # ================================================================
    pdf.bounding_box([lx, row3_top], width: left_w) do
      pdf.font_size(6.5) do
        pdf.text "Pay Period", style: :bold
        pdf.text "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"
        pdf.move_down 3
        pdf.text "Pay Date", style: :bold
        pdf.text format_date(pay_period.pay_date)
      end
    end

    # MEMO label
    pdf.bounding_box([lx, row3_top + stub_cfg["memo_y_offset"].to_f], width: left_w) do
      pdf.font_size(6.5) { pdf.text "MEMO:", style: :bold }
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
    last_idx = data.length - 1
    has_total = rows.last.is_a?(Array) && rows.last.first.is_a?(Hash) && rows.last.first[:content] == "TOTAL"

    pdf.bounding_box([x, y], width: w) do
      pdf.font_size(6.5) do
        pdf.table(data, column_widths: col_widths, cell_style: {
          padding: [padding_y, padding_x], borders: [], size: 6.5, overflow: :shrink_to_fit
        }) do
          row(0).borders = [:bottom]
          row(0).border_color = "999999"
          row(0).background_color = "EEEEEE"
          columns(1..-1).align = :right
          if has_total
            row(last_idx).borders = [:top]
            row(last_idx).border_color = "999999"
          end
        end
      end
    end
  rescue Prawn::Errors::CannotFit
    pdf.bounding_box([x, y], width: w) do
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
            rows << [truncate_label(earning.label), fh(earning.hours), fn(earning.rate), fn(earning.amount), fn(earning.amount)]
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
          rows << [truncate_label(earning.label), fh(earning.hours), fn(earning.rate), fn(earning.amount), fn(earning.amount)]
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

    rows << [
      { content: "TOTAL", font_style: :bold }, "", "",
      { content: fn(payroll_item.gross_pay), font_style: :bold },
      { content: fn(ytd[:gross]), font_style: :bold }
    ]
    rows
  end

  def tax_rows
    return [] if employee.contractor?
    rows = []

    # Build FIT label with W-4 context
    fit_parts = ["Federal Income Tax"]
    w4_notes = []
    w4_notes << "Step2" if employee.w4_step2_multiple_jobs?
    w4_notes << "4a" if employee.w4_step4a_other_income.to_f > 0
    w4_notes << "4b" if employee.w4_step4b_deductions.to_f > 0
    if payroll_item.withholding_tax_override.present?
      fit_parts << "*Override"
    elsif w4_notes.any?
      fit_parts << "(#{w4_notes.join(',')})"
    end
    rows << [fit_parts.join(" "), fn(payroll_item.withholding_tax), fn(ytd[:fit])]

    rows << ["Social Security", fn(payroll_item.social_security_tax), fn(ytd[:ss])]
    rows << ["Medicare", fn(payroll_item.medicare_tax), fn(ytd[:med])]
    rows << ["Addtl W/H (W-4 4c)", fn(payroll_item.additional_withholding), fn(ytd[:addl_wh])] if payroll_item.additional_withholding.to_f > 0

    rows << [
      { content: "TOTAL", font_style: :bold },
      { content: fn(cur_taxes), font_style: :bold },
      { content: fn(ytd[:taxes]), font_style: :bold }
    ]
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

    if rows.any?
      rows << [
        { content: "TOTAL", font_style: :bold },
        { content: fn(cur_deds), font_style: :bold },
        { content: fn(ytd[:deds]), font_style: :bold }
      ]
    end
    rows
  end

  # -----------------------------------------------------------------------
  # SUMMARY box (bottom-right, with NET PAY below like QuickBooks)
  # -----------------------------------------------------------------------
  def draw_summary_box(pdf, x:, y:, w:, stub_cfg:)
    box_h = stub_cfg["summary_box_h"].to_f

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

    data = [header] + data_rows

    pdf.bounding_box([x + 3, y - 3], width: inner_w) do
      pdf.font_size(6.5) do
        pdf.table(data, column_widths: cw, cell_style: {
          padding: [stub_cfg["summary_padding_y"].to_f, stub_cfg["summary_padding_x"].to_f], borders: [], size: 6.5
        }) do
          row(0).borders = [:bottom]
          row(0).border_color = "999999"
          row(0).background_color = "EEEEEE"
          columns(1..2).align = :right
        end
      rescue Prawn::Errors::CannotFit
        pdf.text "[SUMMARY]", size: 6, color: "CC0000"
      end
    end

    net_y = y - box_h - 8
    amount_text = fd(payroll_item.net_pay)
    pdf.font_size(7) do
      pdf.draw_text "NET PAY:", at: [x + 3, net_y], style: :bold
    end
    pdf.font_size(9) do
      amount_w = pdf.width_of(amount_text, style: :bold)
      pdf.draw_text amount_text, at: [x + w - amount_w - 3, net_y], style: :bold
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
      %i[date payee amount amount_words memo signature].each do |field|
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

  def w4_transparency_lines
    return [] if employee.contractor?
    lines = []
    lines << "Filing: #{employee.filing_status&.titleize}"
    lines << "Step 2: Yes (two jobs)" if employee.w4_step2_multiple_jobs?
    lines << "Step 3: #{fn(employee.w4_dependent_credit)} dep. credit" if employee.w4_dependent_credit.to_f > 0
    lines << "Step 4a: #{fn(employee.w4_step4a_other_income)} other income" if employee.w4_step4a_other_income.to_f > 0
    lines << "Step 4b: #{fn(employee.w4_step4b_deductions)} deductions" if employee.w4_step4b_deductions.to_f > 0
    lines << "Step 4c: #{fn(payroll_item.additional_withholding)} addtl W/H" if payroll_item.additional_withholding.to_f > 0
    lines << "* FIT Override: #{fn(payroll_item.withholding_tax_override)}" if payroll_item.withholding_tax_override.present?
    lines
  end

  def resolve_memo_text
    template = company&.check_memo_template.presence
    return "Payroll #{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}" unless template

    template
      .gsub("{employee_name}", employee.full_name)
      .gsub("{employee_first_name}", employee.first_name.to_s)
      .gsub("{employee_last_name}", employee.last_name.to_s)
      .gsub("{period_start}", format_date(pay_period.start_date))
      .gsub("{period_end}", format_date(pay_period.end_date))
      .gsub("{pay_date}", format_date(pay_period.pay_date))
      .gsub("{check_number}", payroll_item.check_number.to_s)
      .gsub("{company_name}", company&.name.to_s)
  end

  def label_or(default)
    default
  end

  def truncate_label(text, max = 20)
    text.to_s.length > max ? "#{text[0, max - 2]}.." : text.to_s
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
