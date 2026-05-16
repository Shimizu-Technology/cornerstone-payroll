# frozen_string_literal: true

require "prawn"
require "prawn/table"
require "active_support/number_helper"

class NonEmployeeCheckVoucherGenerator
  include ActiveSupport::NumberHelper

  TEXT_DARK = "111827"
  TEXT_MUTED = "64748B"
  BORDER = "CBD5E1"
  HEADER_BG = "EAF2FF"

  attr_reader :check, :company

  def initialize(non_employee_check)
    @check = non_employee_check
    @company = non_employee_check.company
  end

  def generate
    Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: 36) do |pdf|
      render_header(pdf)
      render_summary(pdf)
      render_line_items(pdf)
      render_notes(pdf)
      render_footer(pdf)
      draw_void_watermark(pdf) if check.voided?
    end.render
  end

  def filename
    date = check.effective_payment_date.strftime("%Y%m%d")
    safe_payee = check.payable_to.to_s.gsub(/[^a-zA-Z0-9_-]/, "_").first(30)
    "payment_voucher_#{check.check_number || check.id}_#{safe_payee}_#{date}.pdf"
  end

  private

  def render_header(pdf)
    pdf.fill_color TEXT_DARK
    pdf.font_size(16) { pdf.text company.name, style: :bold }
    pdf.move_down 2
    pdf.font_size(11) { pdf.text "Payment Voucher / Remittance Stub", color: TEXT_MUTED }
    pdf.move_down 14
  end

  def render_summary(pdf)
    rows = [
      [ "Payable To", check.payable_to, "Check #", check.check_number.presence || "Unassigned" ],
      [ "Payment Date", format_date(check.effective_payment_date), "Amount", fd(check.amount) ],
      [ "Payment Type", check_type_label, "", "" ],
      [ "Tax/Reporting Period", period_label.presence || "N/A", "Due Date", format_date(check.due_date) ],
      [ "Reference #", check.reference_number.presence || "N/A", "Confirmation #", check.confirmation_number.presence || "N/A" ]
    ]

    pdf.table(rows, column_widths: [ 110, 180, 95, 145 ], cell_style: {
      borders: [ :bottom ],
      border_color: BORDER,
      padding: [ 6, 6 ],
      size: 8.5
    }) do
      columns([ 0, 2 ]).font_style = :bold
      columns([ 0, 2 ]).text_color = TEXT_MUTED
      columns([ 1, 3 ]).text_color = TEXT_DARK
    end
    pdf.move_down 18
  end

  def render_line_items(pdf)
    pdf.font_size(10) { pdf.text "Payment Detail", style: :bold, color: TEXT_DARK }
    pdf.move_down 6

    data = [
      [
        { content: "Description", font_style: :bold },
        { content: "Reference", font_style: :bold },
        { content: "Period", font_style: :bold },
        { content: "Amount", font_style: :bold, align: :right }
      ]
    ]

    check.voucher_line_items.each do |item|
      data << [
        item.description,
        item.reference_number.presence || "N/A",
        item.service_period.presence || period_label.presence || "N/A",
        { content: fd(item.amount), align: :right }
      ]
    end

    data << [
      { content: "TOTAL", colspan: 3, font_style: :bold, align: :right },
      { content: fd(check.amount), font_style: :bold, align: :right }
    ]

    pdf.table(data, header: true, column_widths: [ 235, 105, 95, 95 ], cell_style: {
      border_color: BORDER,
      padding: [ 6, 6 ],
      size: 8
    }) do
      row(0).background_color = HEADER_BG
      row(0).text_color = TEXT_DARK
      row(data.length - 1).background_color = "F8FAFC"
    end
    pdf.move_down 16
  end

  def render_notes(pdf)
    memo_text = check.memo.presence || "N/A"
    description_text = check.description.presence || "N/A"

    pdf.font_size(10) { pdf.text "Purpose / Notes", style: :bold, color: TEXT_DARK }
    pdf.move_down 6
    pdf.table([
      [ "Memo", memo_text ],
      [ "Description", description_text ]
    ], column_widths: [ 95, 435 ], cell_style: {
      border_color: BORDER,
      padding: [ 6, 6 ],
      size: 8
    }) do
      columns(0).font_style = :bold
      columns(0).text_color = TEXT_MUTED
    end
  end

  def render_footer(pdf)
    pdf.move_down 18
    pdf.stroke_color BORDER
    pdf.stroke_horizontal_rule
    pdf.move_down 8
    pdf.font_size(7.5) do
      pdf.fill_color TEXT_MUTED
      pdf.text "Keep this voucher with the invoice, tax notice, receipt, or bank record that supports the payment."
      pdf.text "Generated #{Time.current.strftime('%m/%d/%Y %I:%M %p')}."
    end
  end

  def check_type_label
    {
      "contractor" => "Contractor Payment",
      "tax_deposit" => "Tax Deposit",
      "grt" => "GRT Payment",
      "estimated_tax" => "Estimated Tax",
      "w1_balance" => "W-1 Balance",
      "swica" => "SWICA",
      "child_support" => "Child Support",
      "garnishment" => "Garnishment",
      "vendor" => "Vendor Payment",
      "reimbursement" => "Reimbursement",
      "other" => "Other Payment"
    }[check.check_type] || check.check_type.to_s.titleize
  end

  def period_label
    case check.payment_period_type
    when "month"
      return nil if check.tax_year.blank? || check.tax_month.blank?
      "#{Date::MONTHNAMES[check.tax_month]} #{check.tax_year}"
    when "quarter"
      return nil if check.tax_year.blank? || check.tax_quarter.blank?
      "Q#{check.tax_quarter} #{check.tax_year}"
    when "year"
      check.tax_year&.to_s
    when "pay_period"
      return nil unless check.pay_period
      "#{format_date(check.pay_period.start_date)} - #{format_date(check.pay_period.end_date)}"
    end
  end

  def format_date(date)
    date&.strftime("%m/%d/%Y") || "N/A"
  end

  def fd(value)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', value.to_f))}"
  end

  def draw_void_watermark(pdf)
    pdf.save_graphics_state do
      pdf.fill_color "FFCCCC"
      pdf.transparent(0.25) do
        pdf.font_size(96) do
          pdf.rotate(30, origin: [306, 396]) do
            pdf.draw_text "VOID", at: [180, 360], style: :bold
          end
        end
      end
    end
  end
end
