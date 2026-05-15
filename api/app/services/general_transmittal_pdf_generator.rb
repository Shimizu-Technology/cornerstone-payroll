# frozen_string_literal: true

require "prawn"
require "prawn/table"

class GeneralTransmittalPdfGenerator
  HEADER_COLOR = "2B4090"
  TEXT_MUTED = "666666"

  attr_reader :transmittal, :company

  def initialize(transmittal)
    @transmittal = transmittal
    @company = transmittal.company
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [ 36, 50, 36, 50 ])
    render_header(pdf)
    render_summary(pdf)
    render_items(pdf)
    render_notes(pdf)
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

    pdf.font_size(14) { pdf.text preparer_name, style: :bold, color: HEADER_COLOR }
    pdf.move_down 2
    pdf.font_size(12) { pdf.text "General Transmittal", style: :bold }
    pdf.move_down 2
    pdf.font_size(11) { pdf.text company.name }

    pdf.font_size(9) do
      pdf.bounding_box([ pdf.bounds.width - 200, y_start ], width: 200) do
        pdf.text "Received by: _____________________"
        pdf.move_down 6
        pdf.text "Date Rec'd: ______________________"
      end
    end
    pdf.move_cursor_to(y_start - 58)
  end

  def render_summary(pdf)
    rows = [
      [ "Date:", format_date(transmittal.transmittal_date) ],
      [ "Title:", transmittal.title ],
      [ "Client:", company.name ]
    ]
    rows << [ "Recipient:", transmittal.recipient_name ] if transmittal.recipient_name.present?

    pdf.table(rows, cell_style: { borders: [], padding: [ 2, 6, 2, 0 ], size: 10 }) do
      column(0).font_style = :bold
      column(0).width = 78
      column(1).width = pdf.bounds.width - 78
    end
    pdf.move_down 14
  end

  def render_items(pdf)
    pdf.font_size(11) { pdf.text "Items Provided:", style: :bold }
    pdf.move_down 8

    if transmittal.items.empty?
      pdf.font_size(10) { pdf.text "No items listed.", color: TEXT_MUTED }
      return
    end

    transmittal.items.each_with_index do |item, idx|
      render_item(pdf, item, idx + 1)
      pdf.move_down 8
    end

    return unless total_amount.positive?

    pdf.move_down 4
    pdf.stroke_horizontal_rule
    pdf.move_down 6
    pdf.font_size(10) do
      pdf.text "Total Listed Amount: #{fmt(total_amount)}", style: :bold, align: :right
    end
  end

  def render_item(pdf, item, number)
    pdf.font_size(10) do
      pdf.text "#{number})  #{item.title}", style: :bold
      pdf.indent(30) do
        pdf.text "Check #: #{item.check_number}" if item.check_number.present?
        pdf.text "Payable to: #{item.payable_to}" if item.payable_to.present?
        pdf.text "Amount: #{fmt(item.amount)}" if item.amount.present?
        Array(item.details).each do |detail|
          next if detail.blank?

          pdf.text detail.to_s
        end
      end
    end
  end

  def render_notes(pdf)
    return if transmittal.notes.blank?

    pdf.move_down 12
    pdf.stroke_horizontal_rule
    pdf.move_down 8
    pdf.font_size(10) do
      pdf.text "Notes:", style: :bold
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
    transmittal.items.sum { |item| (item.amount || 0).to_d }
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
