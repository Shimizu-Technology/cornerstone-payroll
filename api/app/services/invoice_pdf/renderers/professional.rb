# frozen_string_literal: true

module InvoicePdf
  module Renderers
    # Professional (Professional.html): a centered letterhead closed by a
    # double accent rule, a serif "Invoice" title, italic serif labels,
    # black rules around the table header and a double-rule "Amount due".
    # Source Serif 4 headings, Source Sans 3 body.
    class Professional < Base
      SERIF = "SourceSerif4"
      TEXT = "22201D"
      SECONDARY = "57534E"
      HAIRLINE = "D6D3D1"
      MARK_SIZES = { "small" => px(40), "medium" => px(52), "large" => px(68) }.freeze

      private

      def margins
        [ px(56), px(68), px(44), px(68) ]
      end

      def font_families
        [ "SourceSans3", SERIF ]
      end

      def body_font
        "SourceSans3"
      end

      def ink
        TEXT
      end

      def muted
        SECONDARY
      end

      def body_size
        px(14)
      end

      def serif_label(value)
        text(value, family: SERIF, style: :italic, color: SECONDARY)
      end

      def draw_header
        draw_letterhead
        pdf.move_down(px(26))
        draw_title_row
        pdf.move_down(px(26))
        draw_parties
        pdf.move_down(px(26))
      end

      def draw_letterhead
        size = MARK_SIZES.fetch(style.logo_size)
        top = pdf.cursor
        if logo?
          width, height = logo_fit(size * 4, size)
          draw_logo((pdf.bounds.width - width) / 2, top, width, height)
        else
          height = size
          monogram((pdf.bounds.width - size) / 2, top, size, font_size: size * 20 / 52, border: style.accent,
                                                             color: style.accent_text, family: SERIF, font_style: :semibold)
        end
        pdf.move_cursor_to(top - height)
        pdf.move_down(px(6))
        text(data.sender_name, size: px(24), family: SERIF, style: :semibold, align: :center, spacing: px(0.5), height: 1.3)
        contact = [ data.sender_address_lines.join(", ").presence, data.billing["phone"], data.billing["email"],
                    data.billing["website"] ].compact_blank.join(" · ")
        if contact.present?
          pdf.move_down(px(6))
          text(contact, size: px(13), color: SECONDARY, align: :center)
        end
        pdf.move_down(px(18))
        double_rule(0, pdf.bounds.width, pdf.cursor, style.accent)
        pdf.move_down(px(3))
      end

      def meta_rows
        [
          [ "Invoice number", data.display_number, :semibold ],
          [ "Date", data.long_date(data.invoice_date), :normal ],
          [ "Due", data.long_date(data.due_date), :normal ],
          [ "Reference", data.customer_reference, :normal ]
        ].select { |_label, value, _style| value.present? }
      end

      def draw_title_row
        rows = meta_rows
        value_width = rows.map { |_l, value, value_style| text_width(value, size: px(13), style: value_style) }.max.to_f + 2
        label_width = rows.map { |row_label, _v, _s| text_width(row_label, size: px(13)) }.max.to_f + 2
        grid_width = label_width + px(20) + value_width
        grid_x = pdf.bounds.width - grid_width
        top = pdf.cursor
        grid = lambda do
          rows.each_with_index do |(row_label, value, value_style), index|
            pdf.move_down(px(2)) if index.positive?
            columns_row([
              column(grid_x, label_width) { text(row_label, size: px(13), color: SECONDARY) },
              column(grid_x + label_width + px(20), value_width) { text(value, size: px(13), style: value_style, align: :right) }
            ])
          end
        end
        grid_height = measure { grid.call }
        title_height = px(28) * 1.3
        height = [ grid_height, title_height ].max
        pdf.move_cursor_to(top - (height - grid_height))
        grid.call
        pdf.move_cursor_to(top - (height - title_height))
        text("Invoice", size: px(28), family: SERIF, color: style.accent_text, height: 1.3)
        pdf.move_cursor_to(top - height)
      end

      def draw_parties
        gap = px(32)
        width = (pdf.bounds.width - gap) / 2
        period = style.show_service_period ? data.service_period_label : nil
        entries = [ column(0, width) { prepared_for } ]
        if period || data.terms
          entries << column(width + gap, width) do
            stack([
              -> { serif_label("For services rendered") },
              (period ? -> { text(period, style: :semibold) } : nil),
              (data.terms ? -> { text("Terms: #{data.terms}") } : nil)
            ], gap: px(2))
          end
        end
        columns_row(entries)
      end

      def prepared_for
        stack([
          -> { serif_label("Prepared for") },
          -> { text(data.recipient_name, style: :semibold) },
          *data.recipient_address_lines.map { |line| -> { text(line) } }
        ], gap: px(2))
      end

      def columns
        @columns ||= begin
          cols = []
          cols << Column.new(key: :item, label: "Service", width: px(180)) if item_column?
          cols << Column.new(key: :description, label: "Description")
          cols << Column.new(key: :date, label: "Date", width: px(80)) if date_column?
          cols << Column.new(key: :quantity, label: "Qty", width: px(40), align: :right)
          cols << Column.new(key: :rate, label: "Rate", width: px(92), align: :right)
          cols << Column.new(key: :amount, label: "Amount", width: px(100), align: :right)
          column_layout(resolve_columns(cols, total_width: pdf.bounds.width, inset: 0, gap: px(12)), gap: px(12))
        end
      end

      def draw_table_header
        rule_at_cursor(TEXT)
        draw_header_cells(columns, padding_top: px(8), padding_bottom: px(8), size: px(12), style: :semibold,
                                   spacing: px(0.4))
        rule_at_cursor(TEXT)
      end

      def draw_row(line, _index)
        draw_cells(line, columns, padding: px(12), cell_styles: { item: { style: :semibold } })
        rule_at_cursor(HAIRLINE)
      end

      def draw_closing
        pdf.move_down(px(14))
        width = px(270)
        pdf.bounding_box([ pdf.bounds.width - width, pdf.cursor ], width: width) do
          total_rows.each do |row_label, value|
            label_value(row_label, value, x: 0, width: width)
            pdf.move_down(px(6))
          end
          double_rule(0, width, pdf.cursor, style.accent)
          pdf.move_down(px(3) + px(8))
          serif = { family: SERIF, style: :semibold, size: px(18), height: 1.3 }
          label_value("Amount due", data.money(data.total), x: 0, width: width, label_options: serif, value_options: serif)
        end
        return unless data.notes

        pdf.move_down(px(26))
        serif_label("Notes")
        pdf.move_down(px(4))
        text(data.notes)
      end

      def draw_footer_block
        instructions = style.show_how_to_pay ? data.payment_instructions : nil
        note = data.footer_note
        return unless instructions || note

        if instructions
          serif_label("Remittance")
          pdf.move_down(px(6))
          text(instructions)
        end
        return unless note

        pdf.move_down(px(16)) if instructions
        text(note, family: SERIF, style: :italic, color: SECONDARY, align: :center)
      end
    end
  end
end
