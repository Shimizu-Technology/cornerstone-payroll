# frozen_string_literal: true

module InvoicePdf
  module Renderers
    # Modern (Modern.html): a small round mark beside the name, a large
    # "Amount due" figure, a Billed to | From | Details strip between
    # hairlines, a service-first line table and a gray "How to pay" panel.
    # Space Grotesk headings, Inter body.
    class Modern < Base
      HEADING = "SpaceGrotesk"
      TEXT = "1C1917"
      SECONDARY = "57534E"
      BODY_MUTED = "44403C"
      LABEL = "78716C"
      HAIRLINE = "E7E5E4"
      PANEL = "F5F5F4"
      MARK_SIZES = { "small" => px(28), "medium" => px(36), "large" => px(48) }.freeze
      MIN_NAME_WIDTH = px(180)

      private

      def margins
        [ px(64), px(64), px(44), px(64) ]
      end

      def font_families
        [ "Inter", HEADING ]
      end

      def body_font
        "Inter"
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

      def label(value)
        text(value, size: px(11), style: :medium, color: LABEL, spacing: px(1))
      end

      def draw_header
        draw_identity_row
        pdf.move_down(px(36))
        draw_amount_due
        pdf.move_down(px(36))
        draw_strip
        pdf.move_down(px(36))
      end

      def draw_identity_row
        top = pdf.cursor
        size = MARK_SIZES.fetch(style.logo_size)
        if logo?
          mark_width, mark_height = logo_fit(size * 4, size)
          draw_logo(0, top, mark_width, mark_height)
        else
          mark_width = mark_height = size
          monogram(0, top, size, font_size: size * 14 / 36, border: style.accent, round: true,
                                 color: style.accent_text, family: HEADING, font_style: :bold)
        end
        name_height = px(17) * 1.5
        row_height = [ mark_height, name_height ].max
        number = data.display_number
        number_width = text_width(number, size: px(15), family: HEADING, style: :semibold) + 1
        prefix_width = text_width("Invoice ", size: px(15), family: HEADING) + 1
        right_width = number_width + prefix_width
        name_x = mark_width + px(12)
        name_top = top - ((row_height - name_height) / 2)
        # A long invoice number moves to its own line so the name keeps room.
        stacked = pdf.bounds.width - name_x - right_width - px(16) < MIN_NAME_WIDTH
        name_width = pdf.bounds.width - name_x - (stacked ? 0 : right_width + px(16))
        font_box(data.sender_name, x: name_x, top: name_top - (px(17) * 0.25), width: name_width,
                                   size: px(17), family: HEADING, style: :semibold, color: TEXT)
        pdf.move_cursor_to(top - row_height)
        return draw_stacked_number(number) if stacked

        meta_top = top - ((row_height - (px(15) * 1.5)) / 2) - (px(15) * 0.25)
        font_box(number, x: pdf.bounds.width - number_width, top: meta_top, width: number_width, size: px(15),
                         family: HEADING, style: :semibold, color: TEXT, align: :right)
        font_box("Invoice", x: pdf.bounds.width - right_width, top: meta_top, width: prefix_width, size: px(15),
                            family: HEADING, color: SECONDARY)
      end

      def draw_stacked_number(number)
        pdf.move_down(px(12))
        text("Invoice #{number}", size: px(15), family: HEADING, style: :semibold, color: TEXT)
      end

      def draw_amount_due
        text("AMOUNT DUE", size: px(12), style: :medium, color: style.accent_text, spacing: px(1.2), height: 1.5)
        pdf.move_down(px(6))
        text(data.money(data.total), size: px(52), family: HEADING, style: :semibold, color: TEXT, spacing: -px(1),
                                     height: 1.05)
        due = [ data.due_date && "Due #{data.long_date(data.due_date)}", data.terms ].compact.join(" · ").presence
        return unless due

        pdf.move_down(px(6))
        text(due, color: SECONDARY)
      end

      def draw_strip
        rule_at_cursor(HAIRLINE)
        pdf.move_down(px(22))
        gap = px(28)
        width = (pdf.bounds.width - (gap * 2)) / 3
        fitting_columns([
          column(0, width) { billed_to },
          column(width + gap, width) { from },
          column((width + gap) * 2, width) { details }
        ])
        pdf.move_down(px(22))
        rule_at_cursor(HAIRLINE)
      end

      def billed_to
        stack([
          -> { label("BILLED TO") },
          -> { text(data.recipient_name, style: :semibold) },
          *data.recipient_address_lines.map { |line| -> { text(line, color: BODY_MUTED) } }
        ], gap: px(2))
      end

      def from
        stack([
          -> { label("FROM") },
          -> { text(data.sender_name, style: :semibold) },
          *data.sender_address_lines.map { |line| -> { text(line, color: BODY_MUTED) } },
          *Array(data.billing["email"].presence).map { |line| -> { text(line, color: BODY_MUTED) } }
        ], gap: px(2))
      end

      def details
        issued = data.invoice_date && "#{data.draft? ? 'Dated' : 'Issued'} #{data.short_date(data.invoice_date)}"
        period = style.show_service_period && data.service_period_label && "Service period #{data.service_period_label}"
        reference = data.customer_reference && "Reference #{data.customer_reference}"
        stack([
          -> { label("DETAILS") },
          *[ issued, period, reference ].compact.map { |line| -> { text(line, color: BODY_MUTED) } }
        ], gap: px(2))
      end

      def columns
        @columns ||= begin
          cols = [ Column.new(key: :service, label: item_column? ? "SERVICE" : "DESCRIPTION") ]
          cols << Column.new(key: :date, label: "DATE", width: px(80)) if date_column?
          cols << Column.new(key: :quantity, label: "QTY", width: px(44), align: :right)
          cols << Column.new(key: :rate, label: "RATE", width: px(96), align: :right)
          cols << Column.new(key: :amount, label: "AMOUNT", width: px(104), align: :right)
          column_layout(resolve_columns(cols, total_width: pdf.bounds.width, inset: 0, gap: px(16)), gap: px(16))
        end
      end

      def draw_table_header
        draw_header_cells(columns, padding_top: 0, padding_bottom: px(10), size: px(11), style: :medium, color: LABEL,
                                   spacing: px(1))
      end

      def draw_row(line, index)
        rule_at_cursor(HAIRLINE)
        pdf.move_down(px(16))
        columns_row(columns.map do |col, x|
          column(x, col.width) do
            if col.key == :service
              service_cell(line)
            else
              text(line_value(line, col.key, index), align: col.align || :left, style: col.key == :amount ? :medium : :normal)
            end
          end
        end)
        pdf.move_down(px(16))
      end

      # The item name sits over its description.
      def service_cell(line)
        name = item_column? && !line["continued"] ? line["item_name"].presence : nil
        return text(line["description"].to_s) unless name

        text(name, style: :semibold)
        pdf.move_down(px(2))
        text(line["description"].to_s, color: SECONDARY)
      end

      def close_table_segment(final: false)
        rule_at_cursor(HAIRLINE)
      end

      def draw_closing
        pdf.move_down(px(18))
        width = px(260)
        pdf.bounding_box([ pdf.bounds.width - width, pdf.cursor ], width: width) do
          total_rows.each do |row_label, value|
            label_value(row_label, value, x: 0, width: width, label_options: { color: SECONDARY },
                                          value_options: { color: SECONDARY })
            pdf.move_down(px(8))
          end
          label_value("Total due", data.money(data.total), x: 0, width: width,
                                                           label_options: { family: HEADING, style: :semibold, size: px(18), height: 1.3 },
                                                           value_options: { family: HEADING, style: :semibold, size: px(18), height: 1.3,
                                                                            color: style.accent_text })
        end
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

        content = lambda do
          stack([
            (instructions ? -> { label("HOW TO PAY") } : nil),
            (instructions ? -> { text(instructions) } : nil),
            (note ? -> { text(note, color: SECONDARY) } : nil)
          ], gap: px(6))
        end
        panel(fill: PANEL, radius: px(10), pad_x: px(20), pad_y: px(18), fallback: content, &content)
      end
    end
  end
end
