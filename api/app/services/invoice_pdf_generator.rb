# frozen_string_literal: true

require "prawn"
require "prawn/table"

class InvoicePdfGenerator
  include ActionView::Helpers::NumberHelper

  PAGE_MARGIN = 48
  PAGE_BOTTOM_MARGIN = 68
  INK = "111827"
  MUTED = "526176"
  LINE = "DCE4EB"
  PANEL = "F3F6F8"
  ACCENT = "0A8278"
  ACCENT_SOFT = "EAF5F2"
  NAVY = "192D47"

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
    top = pdf.cursor
    logo = InvoiceLogoStorageService.new.download(billing) if billing["logo_storage_key"].present?
    if logo
      pdf.bounding_box([ 0, top ], width: 82, height: 55) do
        pdf.image StringIO.new(logo), fit: [ 78, 50 ]
      end
    end

    pdf.bounding_box([ logo ? 96 : 0, top ], width: pdf.bounds.width - (logo ? 96 : 0), height: 64) do
      pdf.fill_color NAVY
      pdf.text billing["legal_name"].presence || billing["name"].to_s, size: 16, style: :bold
      pdf.move_down 6
      pdf.fill_color MUTED
      contact_lines.each { |line| pdf.text line, size: 8.5, leading: 2 }
    end
    pdf.move_cursor_to(top - 78)
  end

  def invoice_title(pdf)
    rows = [
      [ "Invoice Date", format_date(invoice_data["invoice_date"]) ],
      [ "Due Date", format_date(invoice_data["due_date"]) ],
      [ "Service Period", service_period ],
      [ "Customer Reference", invoice_data["customer_reference"] ]
    ].reject { |_label, value| value.blank? }

    top = pdf.cursor
    pdf.fill_color NAVY
    pdf.fill_rectangle [ 0, top ], pdf.bounds.width, 102
    pdf.bounding_box([ 20, top - 19 ], width: pdf.bounds.width - 210, height: 75) do
      pdf.fill_color "A8D9D3"
      pdf.text "INVOICE", size: 10, style: :bold, character_spacing: 2
      pdf.move_down 9
      pdf.fill_color "FFFFFF"
      pdf.text invoice_data["invoice_number"].presence || "Draft", size: 19, style: :bold
    end
    pdf.bounding_box([ pdf.bounds.width - 190, top - 19 ], width: 170, height: 75) do
      pdf.fill_color "A8D9D3"
      pdf.text "TOTAL DUE", size: 9, style: :bold, align: :right, character_spacing: 1.5
      pdf.move_down 7
      pdf.fill_color "FFFFFF"
      pdf.text money(invoice_data["total_amount"]), size: 21, style: :bold, align: :right
    end
    pdf.fill_color INK
    pdf.move_cursor_to(top - 120)

    return if rows.empty?

    metadata = rows.each_slice(2).map do |pair|
      pair.flat_map { |label, value| [ { content: label == "Customer Reference" ? "REFERENCE" : label.upcase,
                                       font_style: :bold, text_color: MUTED }, value.to_s ] }
          .tap { |row| row.concat([ "", "" ]) if row.length == 2 }
    end
    pdf.table(metadata, width: pdf.bounds.width, cell_style: { size: 8.5, padding: [ 5, 7 ], borders: [ :bottom ],
                                                           border_color: LINE, text_color: INK, valign: :top }) do
      columns(0).width = 105
      columns(1).width = (pdf.bounds.width / 2) - 105
      columns(2).width = 110
      columns(3).width = (pdf.bounds.width / 2) - 110
    end
    pdf.move_down 22
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

    pdf.table([ [ bill_to, remit_to ] ], width: pdf.bounds.width, cell_style: { borders: [], padding: [ 0, 18, 0, 0 ],
                                                                              size: 10, text_color: INK, valign: :top }) do
      columns(0).width = pdf.bounds.width / 2
      columns(1).width = pdf.bounds.width / 2
    end
    pdf.move_down 24
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

    pdf.table(rows, header: true, width: table_width, cell_style: { size: 9, padding: [ 11, 9 ],
                                                                   borders: [ :bottom ], border_color: LINE,
                                                                   text_color: INK }) do
      row(0).background_color = NAVY
      row(0).text_color = "FFFFFF"
      row(0).borders = []
      (1...rows.length).each { |index| row(index).background_color = PANEL if index.even? }
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
    subtotal = money(invoice_data["subtotal_amount"] || invoice_data["total_amount"])
    discount = money(invoice_data["discount_amount"] || 0)
    discount_label = if invoice_data["discount_type"] == "percent"
      "Discount (#{format_decimal(invoice_data["discount_value"])}%)"
    else
      "Discount"
    end
    summary_rows = [ [ "Subtotal", subtotal ] ]
    summary_rows << [ discount_label, "-#{discount}" ] if BigDecimal((invoice_data["discount_amount"] || 0).to_s).positive?
    summary_rows << [ "TOTAL DUE", total ]
    summary_table = pdf.make_table(summary_rows, width: 190, cell_style: { size: 9.5, padding: [ 5, 0 ],
                                                                            borders: [], text_color: INK }) do
      columns(0).width = 105
      columns(1).width = 85
      columns(1).align = :right
      row(summary_rows.length - 1).font_style = :bold
      row(summary_rows.length - 1).size = 11
      row(summary_rows.length - 1).text_color = NAVY
    end
    payment_text = visible_payment_instructions
    terms = invoice_data["payment_terms"].presence

    if payment_text.present? || terms.present?
      pdf.table(
        [ [
          { content: payment_block(payment_text, terms), text_color: INK },
          summary_table
        ] ],
        width: pdf.bounds.width,
        cell_style: { borders: [], padding: [ 18, 18 ], size: 9.5, valign: :top }
      ) do
        columns(0).width = pdf.bounds.width - 226
        columns(1).width = 226
        columns(0).background_color = PANEL
        columns(1).background_color = ACCENT_SOFT
        columns(0).valign = :top
        columns(1).valign = :top
      end
    else
      pdf.bounding_box([ pdf.bounds.right - 226, pdf.cursor ], width: 226) do
        pdf.table(
          [ [ summary_table ] ],
          width: 226,
          cell_style: { borders: [], padding: [ 18, 18 ], size: 9.5, background_color: ACCENT_SOFT, valign: :top }
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
    note = billing["footer_note"].presence || "Thank you for your business."
    timestamp_label = invoice_data["status"] == "draft" ? "Draft preview" : "Issued"
    footer_text = [ note, generated_at && "#{timestamp_label} #{format_timestamp(generated_at)}" ].compact.join("  |  ")

    pdf.repeat(:all) do
      pdf.canvas do
        pdf.bounding_box([ PAGE_MARGIN, 34 ], width: pdf.page.dimensions[2] - (PAGE_MARGIN * 2), height: 14) do
          pdf.stroke_color LINE
          pdf.stroke_horizontal_rule
          pdf.move_down 5
          pdf.fill_color MUTED
          pdf.text footer_text, size: 7.5, align: :center
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
    Time.iso8601(value.to_s).utc.strftime("%m/%d/%Y %I:%M %p UTC")
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
