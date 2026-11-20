# frozen_string_literal: true

module InvoicePdf
  module Renderers
    # Banner (Banner.html): a full-width accent band with a white logo tile,
    # the name and invoice number, an overlapping white card (Issued | Due |
    # Service period | Amount due), Bill to | Terms, and a rounded, bordered
    # line table with a shaded header and totals row. Manrope throughout.
    class Banner < Base
      TEXT = "0F172A"
      SECONDARY = "334155"
      LABEL = "64748B"
      HEADER_TEXT = "475569"
      BORDER = "E2E8F0"
      HEADER_FILL = "F1F5F9"
      TOTALS_FILL = "F8FAFC"
      SIDE = px(60)
      INSET = px(16)
      TILE_SIZES = { "small" => px(40), "medium" => px(48), "large" => px(60) }.freeze

      private

      def margins
        [ px(44), SIDE, px(40), SIDE ]
      end

      def body_font
        "Manrope"
      end

      def ink
        TEXT
      end

      def muted
        LABEL
      end

      def line_height
        1.5
      end

      def label(value, color: style.accent_text, spacing: px(1), align: :left)
        text(value, size: px(11), style: :bold, color: color, spacing: spacing, align: align)
      end

      def card_label(value, align: :left)
        text(value, size: px(11), style: :semibold, color: LABEL, align: align)
      end

      def draw_header
        band_bottom = draw_band
        card_bottom = draw_card(band_bottom + px(52))
        pdf.move_cursor_to(card_bottom - pdf.bounds.absolute_bottom - px(30))
        draw_parties
        pdf.move_down(px(28))
      end

      # The band is drawn on the page canvas; returns its bottom edge.
      def draw_band
        size = TILE_SIZES.fetch(style.logo_size)
        top = PAGE_HEIGHT - px(44)
        on = style.on_accent
        tile_width = size
        if logo?
          pad = size * 0.14
          logo_width, logo_height = logo_fit((size * 4) - (pad * 2), size - (pad * 2))
          tile_width = logo_width + (pad * 2)
        end
        number = data.display_number
        number = "##{number}" if number.match?(/\A\d/)
        title_height = (px(13) * 1.5) + (px(28) * 1.25)
        name_x = SIDE + tile_width + px(14)
        name_width = PAGE_WIDTH - SIDE - name_x - px(160)
        name_block = measure { pdf.bounding_box([ 0, pdf.cursor ], width: name_width) { band_identity_text(on) } }
        content_height = [ size, title_height, name_block ].max
        band_height = px(44) + content_height + px(84)

        pdf.canvas do
          fill_box(0, PAGE_HEIGHT, PAGE_WIDTH, band_height, style.accent)
          tile_top = top - ((content_height - size) / 2)
          fill_box(SIDE, tile_top, tile_width, size, "FFFFFF", radius: px(10))
          if logo?
            draw_logo(SIDE + ((tile_width - logo_width) / 2), tile_top - ((size - logo_height) / 2), logo_width, logo_height)
          else
            monogram(SIDE, tile_top, size, font_size: size * 18 / 48, color: style.accent_text, font_style: :extrabold)
          end
          pdf.bounding_box([ name_x, top - ((content_height - name_block) / 2) ], width: name_width) do
            band_identity_text(on)
          end
          right_x = PAGE_WIDTH - SIDE - px(200)
          pdf.bounding_box([ right_x, top - ((content_height - title_height) / 2) ], width: px(200)) do
            pdf.transparent(0.9) do
              text("INVOICE", size: px(13), style: :semibold, color: on, align: :right, spacing: px(2), height: 1.5)
            end
            text(number, size: px(28), style: :extrabold, color: on, align: :right, height: 1.25)
          end
        end
        PAGE_HEIGHT - band_height
      end

      def band_identity_text(color)
        text(data.sender_name, size: px(19), style: :bold, color: color, height: 1.4)
        address = data.sender_address_lines.join(" · ")
        return if address.blank?

        pdf.transparent(0.9) { text(address, color: color) }
      end

      def card_fields
        period = style.show_service_period ? data.service_period_label : nil
        [
          [ data.draft? ? "DATED" : "ISSUED", data.abbreviated_date(data.invoice_date) ],
          [ "DUE", data.abbreviated_date(data.due_date) ],
          (period ? [ "SERVICE PERIOD", period ] : nil)
        ].compact.select { |_label, value| value.present? }
      end

      # Draws the overlapping summary card; returns its bottom edge.
      def draw_card(top)
        width = PAGE_WIDTH - (SIDE * 2)
        pad_y = px(22)
        pad_x = px(26)
        gap = px(20)
        fields = card_fields
        count = fields.size + 1
        col_width = (width - (pad_x * 2) - (gap * (count - 1))) / count
        content = lambda do |origin_x|
          entries = fields.each_with_index.map do |(field, value), index|
            column(origin_x + pad_x + (index * (col_width + gap)), col_width) do
              stack([ -> { card_label(field) }, -> { text(value, style: :semibold) } ], gap: px(2))
            end
          end
          entries << column(origin_x + pad_x + (fields.size * (col_width + gap)), col_width) do
            card_label("AMOUNT DUE", align: :right)
            pdf.move_down(px(2))
            text(data.money(data.total), size: px(20), style: :extrabold, color: style.accent_text, align: :right, height: 1.3)
          end
          columns_row(entries)
        end
        # Labels are left-aligned except the amount, which sits flush right.
        height = measure { content.call(0) } + (pad_y * 2)
        pdf.canvas do
          fill_box(SIDE, top, width, height, "FFFFFF", radius: px(12))
          stroke_box(SIDE, top, width, height, BORDER, radius: px(12))
          pdf.move_cursor_to(top - pad_y)
          content.call(SIDE)
        end
        top - height
      end

      def draw_parties
        gap = px(24)
        width = (pdf.bounds.width - gap) / 2
        columns_row([
          column(0, width) do
            stack([
              -> { label("BILL TO") },
              -> { text(data.recipient_name, style: :bold) },
              *data.recipient_address_lines.map { |line| -> { text(line, color: SECONDARY) } }
            ], gap: px(2))
          end,
          column(width + gap, width) { terms_column }
        ])
      end

      def terms_column
        email = data.billing["email"]
        stack([
          -> { label(data.terms ? "TERMS" : "QUESTIONS") },
          (data.terms ? -> { text(data.terms, style: :bold) } : nil),
          (email ? -> { text(data.terms ? "Questions: #{email}" : email, color: SECONDARY) } : nil),
          (data.billing["phone"] ? -> { text(data.billing["phone"], color: SECONDARY) } : nil),
          (data.customer_reference ? -> { text("Reference: #{data.customer_reference}", color: SECONDARY) } : nil)
        ], gap: px(2))
      end

      def columns
        @columns ||= begin
          cols = []
          cols << Column.new(key: :item, label: "SERVICE", width: px(170)) if item_column?
          cols << Column.new(key: :description, label: "DESCRIPTION")
          cols << Column.new(key: :date, label: "DATE", width: px(80)) if date_column?
          cols << Column.new(key: :quantity, label: "QTY", width: px(40), align: :right)
          cols << Column.new(key: :rate, label: "RATE", width: px(92), align: :right)
          cols << Column.new(key: :amount, label: "AMOUNT", width: px(100), align: :right)
          column_layout(resolve_columns(cols, total_width: pdf.bounds.width, inset: INSET, gap: px(12)),
                        inset: INSET, gap: px(12))
        end
      end

      def table_segment_started
        return if measuring?

        @segment_top = pdf.cursor
        @segment_page = pdf.page_number
      end

      # Frames the rows drawn on this page. The final frame closes after the
      # totals row instead, so the totals sit inside the table.
      def close_table_segment(final: false)
        return if measuring? || final

        frame_segment
      end

      def frame_segment
        stroke_box(0, @segment_top, pdf.bounds.width, @segment_top - pdf.cursor, BORDER, radius: px(10))
      end

      def draw_table_header
        header = -> { draw_header_cells(columns, padding_top: px(10), padding_bottom: px(10), size: px(11), style: :bold, color: HEADER_TEXT, spacing: px(0.6)) }
        height = measure { header.call }
        top = pdf.cursor
        radius = px(10)
        fill_box(0.4, top - 0.4, pdf.bounds.width - 0.8, height, HEADER_FILL, radius: radius)
        fill_box(0.4, top - radius, pdf.bounds.width - 0.8, height - radius, HEADER_FILL)
        header.call
      end

      def draw_row(line, _index)
        rule_at_cursor(BORDER)
        draw_cells(line, columns, padding: px(14), cell_styles: {
          item: { style: :bold },
          description: { color: SECONDARY },
          amount: { style: :semibold }
        })
      end

      def draw_closing
        if !measuring? && @segment_page != pdf.page_number
          # The totals had to move to a page of their own; frame them there.
          table_segment_started
        end
        width = px(250)
        content = lambda do
          pdf.bounding_box([ pdf.bounds.width - INSET - width, pdf.cursor ], width: width) do
            total_rows.each do |row_label, value|
              label_value(row_label, value, x: 0, width: width, label_options: { color: HEADER_TEXT },
                                            value_options: { color: HEADER_TEXT })
              pdf.move_down(px(6))
            end
            totals = { size: px(16), style: :extrabold, height: 1.35 }
            label_value("Total due", data.money(data.total), x: 0, width: width, label_options: totals, value_options: totals)
          end
        end
        height = measure { content.call } + (px(14) * 2)
        top = pdf.cursor
        radius = px(10)
        # Rounded bottom corners, square top edge under the last row.
        fill_box(0.4, top, pdf.bounds.width - 0.8, height - 0.4, TOTALS_FILL, radius: radius)
        fill_box(0.4, top, pdf.bounds.width - 0.8, radius, TOTALS_FILL)
        rule_at_cursor(BORDER)
        pdf.move_down(px(14))
        content.call
        pdf.move_cursor_to(top - height)
        frame_segment unless measuring?
        draw_notes
      end

      def draw_notes
        return unless data.notes

        pdf.move_down(px(28))
        label("NOTES")
        pdf.move_down(px(4))
        text(data.notes)
      end

      def draw_footer_block
        instructions = style.show_how_to_pay ? data.payment_instructions : nil
        note = data.footer_note
        return unless instructions || note

        stack([
          (instructions ? -> { label("HOW TO PAY") } : nil),
          (instructions ? -> { text(instructions) } : nil),
          (note ? -> { text(note, color: HEADER_TEXT) } : nil)
        ], gap: px(4))
      end

      def draw_continuation_header(number)
        fill_box(0, PAGE_HEIGHT, PAGE_WIDTH, 5, style.accent)
        super
      end
    end
  end
end
