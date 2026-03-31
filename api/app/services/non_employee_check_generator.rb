# frozen_string_literal: true

require "prawn"
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

  def draw_check_face(pdf, sect_bot, voided)
    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided

    cfg = DEFAULT_LAYOUT[:check_face]
    date_cfg   = cfg[:date]
    payee_cfg  = cfg[:payee]
    amount_cfg = cfg[:amount]
    words_cfg  = cfg[:amount_words]
    memo_cfg   = cfg[:memo]

    pdf.bounding_box([date_cfg[:x] + ox, sect_bot + date_cfg[:y] + oy], width: date_cfg[:width]) do
      pdf.font_size(date_cfg[:font_size]) { pdf.text check_date_str, align: :right }
    end

    pdf.bounding_box([payee_cfg[:x] + ox, sect_bot + payee_cfg[:y] + oy], width: payee_cfg[:width]) do
      pdf.font_size(payee_cfg[:font_size]) { pdf.text check.payable_to }
    end

    pdf.bounding_box([amount_cfg[:x] + ox, sect_bot + amount_cfg[:y] + oy], width: amount_cfg[:width]) do
      pdf.font_size(amount_cfg[:font_size]) { pdf.text fn(check.amount), align: :right }
    end

    pdf.bounding_box([words_cfg[:x] + ox, sect_bot + words_cfg[:y] + oy], width: words_cfg[:width]) do
      pdf.font_size(words_cfg[:font_size]) { pdf.text NumberToWords.convert(check.amount) }
    end

    pdf.bounding_box([memo_cfg[:x] + ox, sect_bot + memo_cfg[:y] + oy], width: memo_cfg[:width]) do
      pdf.font_size(memo_cfg[:font_size]) { pdf.text check.memo.to_s }
    end
  end

  def draw_stub(pdf, sect_bot, voided)
    lx = 16.0 + ox
    top = sect_bot + 252.0 + oy

    pdf.font_size(7) do
      pdf.draw_text check.payable_to, at: [lx, top], style: :bold
    end

    y = top - 18
    pdf.font_size(7) do
      detail_lines.each do |label, value|
        pdf.draw_text label, at: [lx, y], style: :bold
        pdf.draw_text value.to_s, at: [lx + 120, y]
        y -= 12
      end
    end

    # Amount box
    y -= 8
    box_w = 200.0
    box_h = 28.0
    pdf.stroke_color "333333"
    pdf.line_width 0.8
    pdf.stroke_rectangle [lx, y], box_w, box_h
    pdf.bounding_box([lx + 4, y - 4], width: box_w - 8) do
      pdf.font_size(7) do
        pdf.text "AMOUNT:", style: :bold
      end
      pdf.font_size(10) do
        pdf.text fd(check.amount), style: :bold, align: :right
      end
    end

    draw_void_watermark(pdf, sect_bot, sect_bot + SECTION_HEIGHT) if voided
  end

  def detail_lines
    lines = []
    lines << ["Check Type:", check_type_label]
    lines << ["Check #:", check.check_number] if check.check_number.present?
    lines << ["Date:", check_date_str]
    lines << ["Memo:", check.memo] if check.memo.present?
    lines << ["Description:", check.description] if check.description.present?
    lines << ["Reference #:", check.reference_number] if check.reference_number.present?
    if check.pay_period.present?
      lines << ["Pay Period:", "#{format_date(check.pay_period.start_date)} - #{format_date(check.pay_period.end_date)}"]
    end
    lines
  end

  def check_type_label
    {
      "contractor" => "Contractor",
      "tax_deposit" => "Tax Deposit",
      "child_support" => "Child Support",
      "garnishment" => "Garnishment",
      "vendor" => "Vendor",
      "reimbursement" => "Reimbursement",
      "other" => "Other"
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
