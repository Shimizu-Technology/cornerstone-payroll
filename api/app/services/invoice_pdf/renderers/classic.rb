# frozen_string_literal: true

module InvoicePdf
  module Renderers
    # Classic (Main.html): logo tile and practice details on the left, a
    # light "INVOICE" title and number/date grid on the right, a shaded
    # Bill to | Service period box, an accent-ruled line table and a filled
    # accent "Amount due" bar. Inter throughout.
    class Classic < Base
      TEXT = "1F2933"
      STRONG = "111827"
      SECONDARY = "4B5563"
      LABEL = "6B7280"
      PANEL = "F5F7FA"
      RULE = "D1D5DB"
      HAIRLINE = "E5E7EB"
      MARK_SIZES = { "small" => px(44), "medium" => px(56), "large" => px(72) }.freeze

      private

      def margins
        [ px(56), px(60), px(40) + px(16) + px(20), px(60) ]
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

      def footer_baseline_top
        px(40) + px(16)
      end

      def footer_line
        [ data.sender_name.presence,
          data.billing["email"].present? ? "Questions about this invoice? #{data.billing['email']}" : nil ].compact.join(" · ")
      end

      def draw_header
        top = pdf.cursor
        meta_width = px(250)
        mark_width, mark_height = draw_mark(top)
        # A wide logo sits above the practice details so they keep their width.
        if wide_logo?
          details_x = 0
          details_top = top - mark_height - px(12)
        else
          details_x = mark_width + px(16)
          details_top = top
        end
        pdf.bounding_box([ details_x, details_top ], width: pdf.bounds.width - details_x - meta_width - px(24)) do
          stack([
            -> { text(data.sender_name, size: px(18), style: :bold, color: STRONG, height: 1.3) },
            *data.sender_address_lines.map { |line| -> { text(line, color: SECONDARY) } },
            (data.sender_contact.any? ? -> { text(data.sender_contact.join(" · "), color: SECONDARY) } : nil)
          ], gap: px(2))
        end
        left_bottom = [ pdf.cursor, top - mark_height ].min

        pdf.move_cursor_to(top)
        pdf.bounding_box([ pdf.bounds.width - meta_width, top ], width: meta_width) do
          text("INVOICE", size: px(30), style: :light, color: LABEL, align: :right, spacing: px(4), height: 1.45)
          pdf.move_down(px(10))
          meta_grid
        end
        pdf.move_cursor_to([ left_bottom, pdf.cursor ].min)
        pdf.move_down(px(28))
        draw_parties
      end

      def meta_rows
        [
          [ "Invoice no.", data.display_number, :semibold ],
          [ "Invoice date", data.short_date(data.invoice_date), :normal ],
          [ "Due date", data.short_date(data.due_date), :normal ],
          [ "Terms", data.terms, :normal ],
          [ "Reference", data.customer_reference, :normal ]
        ].select { |_label, value, _style| value.present? }
      end

      def meta_grid
        rows = meta_rows
        width = pdf.bounds.width
        value_width = [ rows.map { |_l, value, value_style| text_width(value, size: body_size, style: value_style) }.max.to_f + 2, width * 0.62 ].min
        label_width = width - value_width - px(18)
        rows.each_with_index do |(label, value, value_style), index|
          pdf.move_down(px(3)) if index.positive?
          columns_row([
            column(0, label_width) { text(label, color: LABEL, align: :right) },
            column(label_width + px(18), value_width) { text(value, style: value_style, align: :right) }
          ])
        end
      end

      def wide_logo?
        logo? && (logo_dimensions[0] / logo_dimensions[1]) >= 2
      end

      # Logo or monogram tile; returns the width and height it occupies.
      def draw_mark(top)
        size = MARK_SIZES.fetch(style.logo_size)
        if logo?
          width, height = logo_fit(size * 3.2, size)
          draw_logo(0, top, width, height)
          [ width, height ]
        else
          monogram(0, top, size, font_size: size * 20 / 56, fill: style.accent, radius: size * 8 / 56,
                                 spacing: px(0.5))
          [ size, size ]
        end
      end

      def draw_parties
        pad_y = px(18)
        pad_x = px(20)
        gap = px(24)
        col_width = (pdf.bounds.width - (pad_x * 2) - gap) / 2
        service = style.show_service_period && data.service_period?
        content = lambda do
          entries = [ column(pad_x, col_width) { bill_to } ]
          entries << column(pad_x + col_width + gap, col_width) { service_period } if service
          columns_row(entries)
        end
        height = measure { content.call } + (pad_y * 2)
        top = pdf.cursor
        fill_box(0, top, pdf.bounds.width, height, PANEL, radius: px(6))
        pdf.move_down(pad_y)
        content.call
        pdf.move_cursor_to(top - height)
        pdf.move_down(px(28))
      end

      def label(value)
        text(value, size: px(11), style: :semibold, color: LABEL, spacing: px(1))
      end

      def bill_to
        stack([
          -> { label("BILL TO") },
          -> { text(data.recipient_name, style: :semibold, color: STRONG) },
          *data.recipient_address_lines.map { |line| -> { text(line) } }
        ], gap: px(2))
      end

      def service_period
        stack([
          -> { label("SERVICE PERIOD") },
          -> { text(data.service_period_label, style: :semibold, color: STRONG) },
          (data.full_month? ? -> { text(data.service_period_range) } : nil)
        ], gap: px(2))
      end

      def columns
        @columns ||= begin
          cols = []
          if item_column?
            cols << Column.new(key: :number, label: "#", width: px(28))
            cols << Column.new(key: :item, label: "PRODUCT OR SERVICE", width: px(170))
          end
          cols << Column.new(key: :description, label: "DESCRIPTION")
          cols << Column.new(key: :date, label: "DATE", width: px(80)) if date_column?
          cols << Column.new(key: :quantity, label: "QTY", width: px(44), align: :right)
          cols << Column.new(key: :rate, label: "RATE", width: px(92), align: :right)
          cols << Column.new(key: :amount, label: "AMOUNT", width: px(96), align: :right)
          column_layout(resolve_columns(cols, total_width: pdf.bounds.width, inset: px(10), gap: px(12)),
                        inset: px(10), gap: px(12))
        end
      end

      def draw_table_header
        stroke_line(0, pdf.bounds.width, pdf.cursor - 0.75, style.accent, 1.5)
        pdf.move_down(1.5)
        draw_header_cells(columns, padding_top: px(9), padding_bottom: px(9), size: px(11), style: :semibold,
                                   color: "374151", spacing: px(0.6))
        rule_at_cursor(RULE)
      end

      def draw_row(line, _index)
        draw_cells(line, columns, padding: px(12), cell_styles: {
          number: { color: LABEL },
          item: { style: :semibold }
        })
        rule_at_cursor(HAIRLINE)
      end

      def draw_closing
        pdf.move_down(px(28))
        width = px(280)
        pdf.bounding_box([ pdf.bounds.width - width, pdf.cursor ], width: width) do
          total_rows.each do |row_label, value|
            label_value(row_label, value, x: 0, width: width, label_options: { color: SECONDARY })
            pdf.move_down(px(6))
          end
          rule_at_cursor(RULE)
          pdf.move_down(px(8))
          label_value("Total", data.money(data.total), x: 0, width: width,
                                                       label_options: { style: :semibold }, value_options: { style: :semibold })
          pdf.move_down(px(12))
          amount_due_bar(width)
        end
        draw_notes
      end

      def amount_due_bar(width)
        height = px(10 * 2) + (px(18) * 1.45)
        top = pdf.y
        fill_box(0, pdf.cursor, width, height, style.accent, radius: px(6))
        pdf.move_down(px(10))
        columns_row([
          column(px(12), width / 2) { text("Amount due", style: :semibold, color: style.on_accent, height: 2.0) },
          column(width / 2, (width / 2) - px(12)) do
            text(data.money(data.total), size: px(18), style: :bold, color: style.on_accent, align: :right)
          end
        ])
        pdf.y = top - height
      end

      def draw_notes
        return unless data.notes

        pdf.move_down(px(24))
        label("NOTES")
        pdf.move_down(px(4))
        text(data.notes)
      end

      def footer_sections
        sections = []
        sections << [ "HOW TO PAY", data.payment_instructions ] if style.show_how_to_pay && data.payment_instructions
        sections << [ "NOTE", data.footer_note ] if data.footer_note
        sections
      end

      def draw_footer_block
        sections = footer_sections
        return if sections.empty?

        rule_at_cursor(HAIRLINE)
        pdf.move_down(px(18))
        gap = px(24)
        col_width = (pdf.bounds.width - gap) / 2
        columns_row(sections.each_with_index.map do |(heading, body), index|
          column(index * (col_width + gap), col_width) do
            label(heading)
            pdf.move_down(px(4))
            text(body)
          end
        end)
      end
    end
  end
end
