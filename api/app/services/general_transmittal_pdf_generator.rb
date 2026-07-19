# frozen_string_literal: true

require "prawn"
require "prawn/table"

class GeneralTransmittalPdfGenerator
  TEMPLATE_VERSION = "unified-transmittal-v1"
  NAVY = "13243A"
  BLUE = "2256A8"
  PALE_BLUE = "EEF4FC"
  PALE_GOLD = "FFF8E7"
  TEXT_MUTED = "64748B"
  BORDER = "D7DFEA"

  attr_reader :transmittal, :company

  def initialize(transmittal)
    @transmittal = transmittal
    @company = transmittal.company
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [ 42, 46, 42, 46 ])
    render_header(pdf)
    render_summary(pdf)
    render_items(pdf)
    render_notes(pdf)
    render_footer(pdf)
    pdf.render
  end

  def filename
    date = transmittal.transmittal_date&.iso8601 || Date.current.iso8601
    safe_title = transmittal.title.to_s.parameterize.presence || "general-transmittal"
    "#{safe_title}_#{date}.pdf"
  end

  private

  def render_header(pdf)
    y_start = pdf.cursor

    pdf.fill_color NAVY
    pdf.font_size(20) { pdf.text "TRANSMITTAL", style: :bold, character_spacing: 0.5 }
    pdf.move_down 5
    pdf.fill_color BLUE
    pdf.font_size(11) { pdf.text transmittal.title, style: :bold }
    pdf.move_down 2
    pdf.fill_color TEXT_MUTED
    pdf.font_size(9) { pdf.text "Prepared by #{preparer_name} for #{company.name}" }

    pdf.bounding_box([ pdf.bounds.width - 196, y_start ], width: 196) do
      pdf.fill_color NAVY
      pdf.font_size(8) { pdf.text "RECEIPT ACKNOWLEDGMENT", style: :bold, character_spacing: 0.7 }
      pdf.move_down 8
      pdf.fill_color TEXT_MUTED
      pdf.font_size(8) do
        pdf.text "Received by  ____________________"
        pdf.move_down 7
        pdf.text "Date received ___________________"
      end
    end
    pdf.move_cursor_to(y_start - 66)
    pdf.stroke_color BORDER
    pdf.stroke_horizontal_rule
    pdf.move_down 14
  end

  def render_summary(pdf)
    rows = [
      [ "TRANSMITTAL DATE", format_date(transmittal.transmittal_date) ],
      [ "CLIENT", company.name ]
    ]
    rows << [ "PAY PERIOD", pay_period_label ] if transmittal.pay_period.present?
    rows << [ "PAY DATE", format_date(transmittal.pay_period.pay_date) ] if transmittal.pay_period&.pay_date
    rows << [ "RECIPIENT", transmittal.recipient_name ] if transmittal.recipient_name.present?

    pdf.table(rows, width: pdf.bounds.width, cell_style: { border_color: BORDER, padding: [ 6, 8 ], size: 9 }) do
      column(0).font_style = :bold
      column(0).text_color = TEXT_MUTED
      column(0).background_color = PALE_BLUE
      column(0).width = 130
      column(1).width = pdf.bounds.width - 130
    end
    pdf.move_down 18
  end

  def render_items(pdf)
    pdf.fill_color NAVY
    pdf.font_size(11) { pdf.text "CONTENTS", style: :bold, character_spacing: 0.7 }
    pdf.move_down 9

    if transmittal.included_items.empty?
      pdf.font_size(10) { pdf.text "No items listed.", color: TEXT_MUTED }
      return
    end

    grouped_items.each do |label, items|
      render_group_heading(pdf, label, items.size)
      items.each_with_index do |item, idx|
        render_item(pdf, item, idx + 1)
      end
      pdf.move_down 9
    end

    return unless total_amount.positive?

    pdf.move_down 4
    pdf.stroke_color BORDER
    pdf.stroke_horizontal_rule
    pdf.move_down 6
    pdf.font_size(10) do
      pdf.fill_color NAVY
      pdf.text "Total listed amount  #{fmt(total_amount)}", style: :bold, align: :right
    end
  end

  def render_item(pdf, item, number)
    pdf.font_size(9) do
      pdf.fill_color NAVY
      pdf.text "#{number}.  #{item.title}", style: :bold
      pdf.indent(18) do
        pdf.fill_color TEXT_MUTED
        pdf.text "Check #: #{item.check_number}" if item.check_number.present?
        pdf.text "Payable to: #{item.payable_to}" if item.payable_to.present?
        pdf.text "Amount: #{fmt(item.amount)}" if item.amount.present?
        if item.calculated_obligation?
          pdf.fill_color "9A6700"
          pdf.text "Calculated obligation — not payment evidence", style: :italic
          pdf.fill_color TEXT_MUTED
        end
        Array(item.details).each do |detail|
          next if detail.blank?

          pdf.text detail.to_s
        end
      end
    end
    pdf.move_down 6
  end

  def render_notes(pdf)
    return if transmittal.notes.blank?

    pdf.move_down 12
    pdf.stroke_color BORDER
    pdf.stroke_horizontal_rule
    pdf.move_down 8
    pdf.font_size(10) do
      pdf.fill_color NAVY
      pdf.text "NOTES", style: :bold, character_spacing: 0.6
      pdf.move_down 4
      transmittal.notes.each_with_index do |note, idx|
        pdf.text "#{idx + 1})  #{note}"
        pdf.move_down 2
      end
    end
  end

  def preparer_name
    transmittal.preparer_name.presence || "Cornerstone Tax Services"
  end

  def total_amount
    transmittal.included_items.sum { |item| (item.amount || 0).to_d }
  end

  def grouped_items
    transmittal.included_items.group_by do |item|
      case item.item_type
      when "check" then "Checks"
      when "report", "document" then "Reports and documents"
      when "tax_obligation" then "Calculated payroll obligations"
      else "Additional items"
      end
    end
  end

  def render_group_heading(pdf, label, count)
    pdf.fill_color(label == "Calculated payroll obligations" ? PALE_GOLD : PALE_BLUE)
    pdf.fill_rectangle [ 0, pdf.cursor ], pdf.bounds.width, 22
    pdf.fill_color NAVY
    pdf.bounding_box([ 8, pdf.cursor - 5 ], width: pdf.bounds.width - 16, height: 16) do
      pdf.font_size(8) { pdf.text "#{label.upcase}  ·  #{count}", style: :bold, character_spacing: 0.4 }
    end
    pdf.move_down 5
  end

  def render_footer(pdf)
    pdf.repeat(:all, dynamic: true) do
      pdf.bounding_box([ 0, -8 ], width: pdf.bounds.width, height: 18) do
        pdf.fill_color TEXT_MUTED
        pdf.font_size(7) do
          pdf.text "Cornerstone Payroll · #{TEMPLATE_VERSION} · Page #{pdf.page_number}", align: :center
        end
      end
    end
  end

  def pay_period_label
    "#{format_date(transmittal.pay_period.start_date)} – #{format_date(transmittal.pay_period.end_date)}"
  end

  def fmt(value)
    number = format("%.2f", value.to_f)
    parts = number.split(".")
    parts[0] = parts[0].reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    "$#{parts.join('.')}"
  end

  def format_date(date)
    date&.strftime("%m/%d/%Y")
  end
end
