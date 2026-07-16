# frozen_string_literal: true

require "prawn"
require "prawn/table"

class InvoicePdfGenerator
  include ActionView::Helpers::NumberHelper

  PAGE_MARGIN = 48
  PAGE_BOTTOM_MARGIN = 68
  INK = "111827"
  MUTED = "6B7280"
  LINE = "D1D5DB"
  PANEL = "F8FAFC"
  ACCENT = "0F766E"
  ACCENT_SOFT = "ECFDF5"

  def initialize(invoice, snapshot: nil)
    @invoice = invoice
    @snapshot = snapshot.presence || invoice.snapshot.presence || invoice.draft_snapshot
  end

  def filename
    number = invoice_data["invoice_number"].to_s.parameterize.presence || "invoice"
    "invoice-#{number}.pdf"
  end

  def generate
    Prawn::Document.new(page_size: "LETTER", margin: [ PAGE_MARGIN, PAGE_MARGIN, PAGE_BOTTOM_MARGIN, PAGE_MARGIN ]) do |pdf|
      letterhead(pdf)
      invoice_title(pdf)
      parties(pdf)
      line_items(pdf)
      totals_and_payment(pdf)
      notes(pdf)
      footer(pdf)
    end.render
  end

  private

  attr_reader :snapshot

  def invoice_data
    snapshot.fetch("invoice", {})
  end

  def billing
    snapshot.fetch("billing_profile", {})
  end

  def recipient
    snapshot.fetch("recipient", {})
  end

  def line_item_rows
    Array(snapshot["line_items"])
  end

  def letterhead(pdf)
    pdf.fill_color INK
    pdf.text billing["legal_name"].presence || billing["name"].to_s, size: 17, style: :bold
    pdf.move_down 4
    pdf.fill_color MUTED
    contact_lines.each { |line| pdf.text line, size: 8.5 }
    pdf.fill_color INK

    pdf.stroke_color LINE
    pdf.line_width 0.75
    pdf.stroke_horizontal_rule
    pdf.move_down 20
  end

  def invoice_title(pdf)
    rows = [
      [ "Invoice Date", format_date(invoice_data["invoice_date"]) ],
      [ "Due Date", format_date(invoice_data["due_date"]) ],
      [ "Service Period", service_period ],
      [ "Customer Reference", invoice_data["customer_reference"] ],
      [ "Status", invoice_data["status"].to_s.titleize.presence || "Draft" ]
    ].reject { |_label, value| value.blank? }

    title = pdf.make_table(
      [
        [ { content: "INVOICE", size: 30, font_style: :bold, text_color: INK } ],
        [ { content: invoice_data["invoice_number"].presence || "Draft", size: 11, font_style: :bold, text_color: ACCENT, padding: [ 4, 0, 0, 0 ] } ]
      ],
      width: 240,
      cell_style: { borders: [], padding: 0 }
    )
    metadata = pdf.make_table(rows, width: 250, cell_style: { size: 9, padding: [ 6, 8 ], border_color: "E5E7EB" }) do
      columns(0).font_style = :bold
      columns(0).text_color = "374151"
      columns(0).background_color = PANEL
      columns(0).width = 95
      columns(1).width = 155
    end

    pdf.table([ [ title, metadata ] ], width: pdf.bounds.width, cell_style: { borders: [], padding: 0, valign: :top }) do
      columns(0).width = pdf.bounds.width - 250
      columns(1).width = 250
    end
    pdf.move_down 20
  end

  def parties(pdf)
    bill_to = labeled_block("Bill To", [
      recipient["name"],
      *recipient["address"].to_s.split("\n"),
      recipient["email"]
    ])
    remit_to = labeled_block("Remit To", [
      billing["remit_to"].presence || billing["legal_name"].presence || billing["name"],
      *billing["address"].to_s.split("\n"),
      billing["email"],
      billing["phone"]
    ])

    pdf.table([ [ bill_to, remit_to ] ], width: pdf.bounds.width, cell_style: { border_color: "E5E7EB", padding: [ 12, 14 ], size: 10, background_color: PANEL, valign: :top }) do
      columns(0).width = pdf.bounds.width / 2
      columns(1).width = pdf.bounds.width / 2
    end
    pdf.move_down 20
  end

  def labeled_block(label, lines)
    body = lines.compact_blank.join("\n")
    "#{label.upcase}\n#{body}"
  end

  def line_items(pdf)
    include_service_date = line_item_rows.any? { |item| item["service_date"].present? }
    rows = [
      [
        { content: "Description", font_style: :bold },
        (include_service_date ? { content: "Date", font_style: :bold } : nil),
        { content: "Qty", font_style: :bold, align: :right },
        { content: "Rate", font_style: :bold, align: :right },
        { content: "Amount", font_style: :bold, align: :right }
      ].compact
    ]

    line_item_rows.each do |item|
      rows << [
        item["description"].to_s,
        (include_service_date ? format_date(item["service_date"]) : nil),
        format_decimal(item["quantity"]),
        money(item["rate"]),
        money(item["amount"])
      ].compact
    end

    table_width = pdf.bounds.width
    date_width = include_service_date ? 74 : 0
    quantity_width = 52
    rate_width = 78
    amount_width = 80

    pdf.table(rows, header: true, width: table_width, cell_style: { size: 9, padding: [ 9, 8 ], border_color: "E5E7EB" }) do
      row(0).background_color = "ECFDF5"
      row(0).text_color = "064E3B"
      columns(0).width = table_width - date_width - quantity_width - rate_width - amount_width
      if include_service_date
        columns(1).width = date_width
        columns(2).width = quantity_width
        columns(3).width = rate_width
        columns(4).width = amount_width
        columns(2..4).align = :right
      else
        columns(1).width = quantity_width
        columns(2).width = rate_width
        columns(3).width = amount_width
        columns(1..3).align = :right
      end
    end
  end

  def totals_and_payment(pdf)
    pdf.move_down 14
    total = money(invoice_data["total_amount"])
    payment_text = visible_payment_instructions
    terms = invoice_data["payment_terms"].presence

    if payment_text.present? || terms.present?
      pdf.table(
        [ [
          { content: payment_block(payment_text, terms) },
          { content: "TOTAL DUE\n#{total}", align: :right, font_style: :bold }
        ] ],
        width: pdf.bounds.width,
        cell_style: { border_color: LINE, padding: [ 14, 14 ], size: 10, valign: :top }
      ) do
        columns(0).width = pdf.bounds.width - 180
        columns(1).width = 180
        columns(0).background_color = PANEL
        columns(1).background_color = ACCENT_SOFT
        columns(0).valign = :top
        columns(1).valign = :top
      end
    else
      pdf.bounding_box([ pdf.bounds.right - 180, pdf.cursor ], width: 180) do
        pdf.table(
          [ [ { content: "TOTAL DUE\n#{total}", align: :right, font_style: :bold } ] ],
          width: 180,
          cell_style: { border_color: LINE, padding: [ 14, 14 ], size: 10, background_color: ACCENT_SOFT, valign: :top }
        )
      end
    end
  end

  def payment_block(payment_text, terms)
    parts = []
    parts << "PAYMENT INSTRUCTIONS\n#{payment_text}" if payment_text.present?
    parts << "TERMS\n#{terms}" if terms.present?
    parts.join("\n\n")
  end

  def visible_payment_instructions
    text = billing["payment_instructions"].to_s.strip.presence
    return nil if text == "Please remit payment according to the instructions on this invoice."

    text
  end

  def notes(pdf)
    return if invoice_data["notes"].blank?

    pdf.move_down 18
    pdf.fill_color INK
    pdf.text "Notes", size: 10, style: :bold
    pdf.move_down 4
    pdf.fill_color "374151"
    pdf.text invoice_data["notes"], size: 9, leading: 2
    pdf.fill_color INK
  end

  def footer(pdf)
    generated_at = snapshot["generated_at"].presence
    note = billing["footer_note"].presence || "Generated by Cornerstone Payroll."
    footer_text = [ note, generated_at && "Generated #{format_timestamp(generated_at)}" ].compact.join(" | ")

    pdf.repeat(:all) do
      pdf.canvas do
        pdf.bounding_box([ PAGE_MARGIN, 34 ], width: pdf.page.dimensions[2] - (PAGE_MARGIN * 2), height: 14) do
          pdf.fill_color "9CA3AF"
          pdf.text footer_text, size: 8, align: :center
          pdf.fill_color INK
        end
      end
    end
  end

  def contact_lines
    [
      billing["address"],
      [ billing["phone"], billing["email"], billing["website"] ].compact_blank.join(" | ").presence
    ].compact_blank.flat_map { |line| line.to_s.split("\n") }
  end

  def service_period
    [ format_date(invoice_data["service_period_start"]), format_date(invoice_data["service_period_end"]) ].compact_blank.join(" - ").presence
  end

  def format_date(value)
    return nil if value.blank?

    Date.parse(value.to_s).strftime("%m/%d/%Y")
  rescue Date::Error
    value.to_s
  end

  def format_timestamp(value)
    Time.zone.parse(value.to_s).strftime("%m/%d/%Y %I:%M %p")
  rescue ArgumentError
    value.to_s
  end

  def format_decimal(value)
    number_with_precision(value || 0, precision: 2, delimiter: ",")
  end

  def money(value)
    number_to_currency(value || 0)
  end
end
