# frozen_string_literal: true

require "prawn"
require "prawn/table"
require "active_support/number_helper"
require_relative "../../lib/number_to_words"

# Generates a check PDF for non-employee checks (tax deposits, vendor payments, etc.).
# Uses the same 3-section letter-size layout as CheckGenerator for consistency
# with pre-printed check stock.
class NonEmployeeCheckGenerator
  PAGE_WIDTH     = 612.0
  PAGE_HEIGHT    = 792.0
  MARGIN         = 0.0
  SECTION_HEIGHT = PAGE_HEIGHT / 3.0
  M              = 16.0

  DEFAULT_LAYOUT = {
    check_face: {
      date:         { x: 474.0, y: 216.0, width: 112.0, font_size: 10.0 },
      payee:        { x: 64.0,  y: 180.0, width: 320.0, font_size: 10.0 },
      amount:       { x: 467.0, y: 182.0, width: 120.0, font_size: 10.0 },
      amount_words: { x: 52.0,  y: 156.0, width: 492.0, font_size: 9.0 },
      memo:         { x: 22.0,  y: 64.0,  width: 260.0, font_size: 7.5 }
    }
  }.freeze

  attr_reader :check, :company

  def initialize(non_employee_check)
    @check   = non_employee_check
    @company = non_employee_check.company
  end

  def generate
    render_document(voided: false)
  end

  def generate_voided
    render_document(voided: check.voided?)
  end

  def filename
    date_token = check.created_at.strftime("%Y%m%d")
    safe_payee = check.payable_to.gsub(/[^a-zA-Z0-9_-]/, "_").first(30)
    "ne_check_#{check.check_number || check.id}_#{safe_payee}_#{date_token}.pdf"
  end

  private

  def ox; (company.check_offset_x.to_f * 72).round(1); end
  def oy; (company.check_offset_y.to_f * 72).round(1); end

  def top_check?
    company.check_stock_type != "bottom_check"
  end

  def check_y;  top_check? ? (SECTION_HEIGHT * 2) : 0;                end
  def stub1_y;  top_check? ? SECTION_HEIGHT       : (SECTION_HEIGHT * 2); end
  def stub2_y;  top_check? ? 0                    : SECTION_HEIGHT;    end

  def render_document(voided: false)
    Prawn::Document.new(
      page_size: [PAGE_WIDTH, PAGE_HEIGHT], page_layout: :portrait, margin: MARGIN
    ) do |pdf|
      draw_check_face(pdf, check_y, voided)
      draw_stub(pdf, stub1_y, voided)
      draw_stub(pdf, stub2_y, voided)
    end.render
  end

  # ---------------------------------------------------------------------------
  # CHECK FACE — matches payroll check layout positions
  # ---------------------------------------------------------------------------
  def draw_check_face(pdf, sect_bot, voided)
    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided

    cfg = DEFAULT_LAYOUT[:check_face]

    # Date (top-right)
    pdf.bounding_box([cfg[:date][:x] + ox, sect_bot + cfg[:date][:y] + oy], width: cfg[:date][:width]) do
      pdf.font_size(cfg[:date][:font_size]) { pdf.text check_date_str, align: :right }
    end

    # Payee (left)
    pdf.bounding_box([cfg[:payee][:x] + ox, sect_bot + cfg[:payee][:y] + oy], width: cfg[:payee][:width]) do
      pdf.font_size(cfg[:payee][:font_size]) { pdf.text check.payable_to }
    end

    # Amount (right)
    pdf.bounding_box([cfg[:amount][:x] + ox, sect_bot + cfg[:amount][:y] + oy], width: cfg[:amount][:width]) do
      pdf.font_size(cfg[:amount][:font_size]) { pdf.text fn(check.amount), align: :right }
    end

    # Amount in words
    pdf.bounding_box([cfg[:amount_words][:x] + ox, sect_bot + cfg[:amount_words][:y] + oy], width: cfg[:amount_words][:width]) do
      pdf.font_size(cfg[:amount_words][:font_size]) { pdf.text NumberToWords.convert(check.amount) }
    end

    # Memo
    pdf.bounding_box([cfg[:memo][:x] + ox, sect_bot + cfg[:memo][:y] + oy], width: cfg[:memo][:width]) do
      pdf.font_size(cfg[:memo][:font_size]) { pdf.text check.memo.to_s }
    end
  end

  # ---------------------------------------------------------------------------
  # STUB — Professional 4-quadrant layout matching payroll check stubs
  # ---------------------------------------------------------------------------
  def draw_stub(pdf, sect_bot, voided)
    usable = PAGE_WIDTH - M * 2
    left_w = usable * 0.56
    right_w = usable - left_w
    lx = M + ox
    rx = lx + left_w
    sy = oy

    row1_top = sect_bot + 252.0 + sy
    row2_top = sect_bot + 176.0 + sy
    row3_top = sect_bot + 118.0 + sy

    # ================================================================
    # ROW 1:  PAYMENT DETAILS (left)  |  CHECK INFO (right)
    # ================================================================
    pdf.font_size(7) do
      pdf.draw_text check.payable_to, at: [lx, row1_top], style: :bold
    end

    draw_section_table(pdf,
      x: lx, y: row1_top - 10, w: left_w - 8,
      title: "PAYMENT DETAILS",
      columns: %w[Amount],
      col_ratios: [0.65, 0.35],
      rows: payment_detail_rows
    )

    draw_section_table(pdf,
      x: rx, y: row1_top - 10, w: right_w,
      title: "CHECK INFO",
      columns: %w[Value],
      col_ratios: [0.45, 0.55],
      rows: check_info_rows
    )

    # ================================================================
    # ROW 2:  MEMO / DESCRIPTION (left)  |  REFERENCE (right)
    # ================================================================
    draw_section_table(pdf,
      x: lx, y: row2_top, w: left_w - 8,
      title: "MEMO / DESCRIPTION",
      columns: %w[],
      col_ratios: [1.0],
      rows: memo_rows
    )

    draw_section_table(pdf,
      x: rx, y: row2_top, w: right_w,
      title: "REFERENCES",
      columns: %w[Value],
      col_ratios: [0.45, 0.55],
      rows: reference_rows
    )

    # ================================================================
    # ROW 3:  Period / Date (left)  |  SUMMARY (right)
    # ================================================================
    pdf.bounding_box([lx, row3_top], width: left_w) do
      pdf.font_size(6.5) do
        if check.pay_period.present?
          pdf.text "Pay Period", style: :bold
          pdf.text "#{format_date(check.pay_period.start_date)} - #{format_date(check.pay_period.end_date)}"
          pdf.move_down 3
        end
        pdf.text "Check Date", style: :bold
        pdf.text check_date_str
      end
    end

    # SUMMARY box (bordered) — matches payroll check style
    draw_summary_box(pdf, x: rx - 18, y: row3_top, w: right_w)

    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided
  end

  # ---------------------------------------------------------------------------
  # Section table helper (same approach as CheckGenerator)
  # ---------------------------------------------------------------------------
  def draw_section_table(pdf, x:, y:, w:, title:, columns:, col_ratios:, rows:)
    return if rows.empty? && columns.empty?

    header = [{ content: title, font_style: :bold }] +
      columns.map { |c| { content: c, font_style: :bold, align: :right } }

    data = [header] + rows
    col_widths = col_ratios.map { |r| w * r }
    last_idx = data.length - 1
    has_total = rows.last.is_a?(Array) && rows.last.first.is_a?(Hash) && rows.last.first[:content] == "TOTAL"

    pdf.bounding_box([x, y], width: w) do
      pdf.font_size(6.5) do
        pdf.table(data, column_widths: col_widths, cell_style: {
          padding: [1, 2], borders: [], size: 6.5, overflow: :shrink_to_fit
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

  # ---------------------------------------------------------------------------
  # SUMMARY box (bottom-right, bordered with NET AMOUNT)
  # ---------------------------------------------------------------------------
  def draw_summary_box(pdf, x:, y:, w:)
    box_h = 48.0

    pdf.stroke_color "333333"
    pdf.line_width 0.8
    pdf.stroke_rectangle [x, y], w, box_h

    inner_w = w - 6
    cw = [inner_w * 0.55, inner_w * 0.45]

    header = [
      { content: "SUMMARY", font_style: :bold },
      { content: "Amount", font_style: :bold }
    ]

    data_rows = [
      [check_type_label, fd(check.amount)]
    ]

    data = [header] + data_rows

    pdf.bounding_box([x + 3, y - 3], width: inner_w) do
      pdf.font_size(6.5) do
        pdf.table(data, column_widths: cw, cell_style: {
          padding: [1.5, 2], borders: [], size: 6.5
        }) do
          row(0).borders = [:bottom]
          row(0).border_color = "999999"
          row(0).background_color = "EEEEEE"
          columns(1).align = :right
        end
      rescue Prawn::Errors::CannotFit
        pdf.text "[SUMMARY]", size: 6, color: "CC0000"
      end
    end

    net_y = y - box_h - 8
    amount_text = fd(check.amount)
    pdf.font_size(7) do
      pdf.draw_text "CHECK AMOUNT:", at: [x + 3, net_y], style: :bold
    end
    pdf.font_size(9) do
      amount_w = pdf.width_of(amount_text, style: :bold)
      pdf.draw_text amount_text, at: [x + w - amount_w - 3, net_y], style: :bold
    end
  end

  # ---------------------------------------------------------------------------
  # Data row builders
  # ---------------------------------------------------------------------------
  def payment_detail_rows
    rows = []
    rows << [check_type_label, fd(check.amount)]
    rows << [
      { content: "TOTAL", font_style: :bold },
      { content: fd(check.amount), font_style: :bold }
    ]
    rows
  end

  def check_info_rows
    rows = []
    rows << ["Check #", check.check_number || "—"]
    rows << ["Date", check_date_str]
    rows << ["Type", check_type_label]
    rows << ["Status", check.check_status.to_s.capitalize]
    rows
  end

  def memo_rows
    rows = []
    rows << [check.memo] if check.memo.present?
    rows << [check.description] if check.description.present?
    rows << ["—"] if rows.empty?
    rows
  end

  def reference_rows
    rows = []
    rows << ["Reference #", check.reference_number] if check.reference_number.present?
    if check.pay_period.present?
      rows << ["Pay Period", "#{format_date(check.pay_period.start_date)} - #{format_date(check.pay_period.end_date)}"]
    end
    rows << ["Created", check.created_at.strftime("%m/%d/%Y")]
    rows
  end

  def check_type_label
    {
      "contractor" => "Contractor Payment",
      "tax_deposit" => "Tax Deposit",
      "child_support" => "Child Support",
      "garnishment" => "Garnishment",
      "vendor" => "Vendor Payment",
      "reimbursement" => "Reimbursement",
      "other" => "Other Payment"
    }[check.check_type] || check.check_type.to_s.titleize
  end

  def check_date_str
    (check.pay_period&.pay_date || check.created_at.to_date).strftime("%m/%d/%Y")
  end

  def format_date(d)
    d&.strftime("%m/%d/%Y") || "N/A"
  end

  def fn(v)
    return "0.00" if v.nil?
    ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", v.to_f))
  end

  def fd(v)
    "$#{fn(v)}"
  end

  def draw_void_watermark(pdf, sect_bot, _sect_top)
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
end
