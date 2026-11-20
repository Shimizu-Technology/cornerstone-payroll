# frozen_string_literal: true

module InvoicePdf
  module Renderers
    # Shared layout engine for the themed invoices.
    #
    # Mockups are US-letter pages at 816 x 1056 CSS px; a PDF point is
    # 0.75 px, so px(n) converts a mockup measurement to points.
    #
    # Pagination: line rows flow down the page and the column header repeats
    # on every page. The last KEEP_WITH_TOTALS rows travel with the totals,
    # so the totals never sit alone on a final page. Page numbers, the
    # continuation header and the draft marker are drawn last, once the page
    # count is known.
    class Base
      PAGE_SIZE = "LETTER"
      PAGE_WIDTH = 612.0
      PAGE_HEIGHT = 792.0
      KEEP_WITH_TOTALS = 2

      Column = Struct.new(:key, :label, :width, :align, keyword_init: true)

      def self.px(value)
        value * 0.75
      end

      def initialize(data:, style:, logo: nil)
        @data = data
        @style = style
        @logo = logo
      end

      def render
        @pdf = new_document
        draw_document
        draw_page_furniture
        @pdf.render
      end

      private

      attr_reader :data, :style, :pdf

      def px(value)
        self.class.px(value)
      end

      # ---- Theme hooks ---------------------------------------------------

      def margins
        raise NotImplementedError
      end

      def font_families
        [ body_font ]
      end

      def body_font
        raise NotImplementedError
      end

      def ink
        "111827"
      end

      def muted
        "6B7280"
      end

      def body_size
        px(13)
      end

      def line_height
        1.45
      end

      def draw_header
        raise NotImplementedError
      end

      def columns
        raise NotImplementedError
      end

      def draw_table_header
        raise NotImplementedError
      end

      def draw_row(_line, _index)
        raise NotImplementedError
      end

      # Totals, discount and invoice notes: drawn right after the last row.
      def draw_closing
        raise NotImplementedError
      end

      # "How to pay" and the footer note: sits at the foot of the last page.
      def draw_footer_block; end

      def footer_line
        nil
      end

      def section_gap
        px(24)
      end

      # Called before a page break inside the line table and once after the
      # last row, so a theme can close a framed table on each page.
      def close_table_segment(final: false); end

      def table_segment_started; end

      # ---- Document ------------------------------------------------------

      def new_document
        doc = PdfUnicodeFont.document(page_size: PAGE_SIZE, margin: margins)
        Fonts.register!(doc, font_families)
        doc.font(body_font)
        doc.default_leading 0
        doc
      end

      def draw_document
        draw_header
        draw_lines
        draw_closing_with_footer
      end

      def draw_lines
        rows = data.lines
        heights = rows.each_with_index.map { |line, index| measure { draw_row(line, index) } }
        tail = measure { draw_closing } + footer_block_height
        header_height = measure { draw_table_header }

        start_table_on_fresh_page_if_needed(header_height + heights.first.to_f)
        table_segment_started
        draw_table_header
        rows.each_with_index do |line, index|
          needed = heights[index]
          if rows.size - index <= KEEP_WITH_TOTALS
            together = heights[index..].sum + tail
            needed = together if together <= pdf.bounds.height - header_height
          end
          if needed > pdf.cursor
            close_table_segment(final: false)
            pdf.start_new_page
            table_segment_started
            draw_table_header
          end
          draw_row(line, index)
        end
        close_table_segment(final: true)
      end

      def start_table_on_fresh_page_if_needed(height)
        pdf.start_new_page if height > pdf.cursor
      end

      def draw_closing_with_footer
        closing = measure { draw_closing }
        pdf.start_new_page if closing > pdf.cursor && closing <= pdf.bounds.height
        draw_closing
        footer = footer_block_height
        return if footer.zero?

        pdf.start_new_page if footer + px(16) > pdf.cursor
        pdf.move_cursor_to(footer) if footer <= pdf.cursor
        draw_footer_block
      end

      def footer_block_height
        @footer_block_height ||= measure { draw_footer_block }
      end

      # Draws the block on an off-screen copy of the document and returns its
      # height. A block that would not fit on one page returns infinity.
      def measuring?
        @measure_depth.to_i.positive?
      end

      # Nested measurements each get their own off-screen document.
      def measure
        real = @pdf
        @scratch_documents ||= []
        @measure_depth = @measure_depth.to_i + 1
        @pdf = (@scratch_documents[@measure_depth - 1] ||= new_document)
        pdf.move_cursor_to(pdf.bounds.height)
        page = pdf.page_number
        start = pdf.cursor
        yield
        pdf.page_number == page ? start - pdf.cursor : Float::INFINITY
      ensure
        @measure_depth -= 1
        @pdf = real
      end

      # ---- Page furniture --------------------------------------------------

      def draw_page_furniture
        total = pdf.page_count
        (1..total).each do |number|
          pdf.go_to_page(number)
          pdf.canvas do
            draw_continuation_header(number) if number > 1
            draw_page_footer(number, total)
          end
        end
      end

      def continuation_label
        [ "Invoice #{data.display_number}", data.sender_name.presence ].compact.join(" · ")
      end

      def draw_continuation_header(_number)
        left = margins[3]
        width = PAGE_WIDTH - margins[1] - left
        top = PAGE_HEIGHT - [ margins[0] - px(26), px(14) ].max
        font_box(continuation_label, x: left, top: top, width: width - 80, size: px(11), color: muted)
        font_box("continued", x: left + width - 80, top: top, width: 80, size: px(11), color: muted, align: :right)
        stroke_line(left, left + width, top - px(20), "E5E7EB", 0.5)
      end

      # Top of the page-number line, inside the bottom page padding.
      def footer_baseline_top
        margins[2] - px(14)
      end

      def draw_page_footer(number, total)
        left = margins[3]
        width = PAGE_WIDTH - margins[1] - left
        top = footer_baseline_top
        center = [ footer_line, data.preview_marker ].compact.join("  ·  ").presence
        if center
          font_box(center, x: left + 70, top: top, width: width - 140, size: px(11), color: muted, align: :center,
                           style: data.preview_marker && !footer_line ? :semibold : :normal)
        end
        return unless total > 1

        font_box("Page #{number} of #{total}", x: left + width - 70, top: top, width: 70, size: px(11), color: muted,
                                               align: :right)
      end

      # ---- Text primitives ---------------------------------------------------

      # Flowing text at the cursor inside the current bounds, with CSS-like
      # line height: the extra leading is split above and below each line.
      def text(value, size: body_size, family: body_font, style: :normal, color: ink, align: :left, spacing: 0,
               height: line_height)
        return if value.blank?

        pdf.font(family, style: style, size: size) do
          leading = [ (size * height) - pdf.font.height, 0 ].max
          pdf.move_down(leading / 2)
          pdf.fill_color color
          pdf.character_spacing(spacing) do
            pdf.text value.to_s, leading: leading, align: align, size: size
          end
          pdf.move_up(leading / 2)
        end
      end

      # A fixed box of text (used outside the flow, e.g. headers and footers).
      def font_box(value, x:, top:, width:, size:, color:, family: body_font, style: :normal, align: :left, spacing: 0,
                   height: nil)
        pdf.font(family, style: style, size: size) do
          pdf.fill_color color
          pdf.character_spacing(spacing) do
            pdf.text_box value.to_s, at: [ x, top ], width: width, height: height || (size * 2.2), size: size,
                                     align: align, overflow: :shrink_to_fit, single_line: height.nil?
          end
        end
      end

      def text_width(value, size:, family: body_font, style: :normal, spacing: 0)
        width = 0
        pdf.font(family, style: style, size: size) do
          width = pdf.width_of(value.to_s, size: size) + (spacing * value.to_s.length)
        end
        width
      end

      # Draws side-by-side columns starting at the cursor. Each entry is
      # [x, width, proc]; the cursor ends below the tallest column. Positions
      # use the absolute y because inside a stretchy bounding box the cursor
      # is measured from a bottom edge that moves as content is drawn.
      def columns_row(entries)
        top = pdf.y
        bottom = entries.map do |x, width, block|
          pdf.y = top
          pdf.bounding_box([ x, pdf.cursor ], width: width) { block.call }
          pdf.y
        end.min
        pdf.y = bottom || top
      end

      def column(x, width, &block)
        [ x, width, block ]
      end

      # Vertical stack with a CSS-style gap between the items that print.
      def stack(items, gap:)
        items.compact_blank.each_with_index do |item, index|
          pdf.move_down(gap) if index.positive?
          item.respond_to?(:call) ? item.call : text(item)
        end
      end

      # ---- Shapes ------------------------------------------------------------

      def fill_box(x, top, width, height, color, radius: 0)
        pdf.fill_color color
        if radius.positive?
          pdf.fill_rounded_rectangle([ x, top ], width, height, radius)
        else
          pdf.fill_rectangle([ x, top ], width, height)
        end
      end

      def stroke_box(x, top, width, height, color, line_width: 0.75, radius: 0)
        pdf.stroke_color color
        pdf.line_width line_width
        if radius.positive?
          pdf.stroke_rounded_rectangle([ x, top ], width, height, radius)
        else
          pdf.stroke_rectangle([ x, top ], width, height)
        end
      end

      def stroke_line(x1, x2, y, color, line_width = 0.75)
        pdf.stroke_color color
        pdf.line_width line_width
        pdf.stroke_line([ x1, y ], [ x2, y ])
      end

      # Two thin rules, the PDF version of CSS "3px double".
      def double_rule(x1, x2, y, color)
        stroke_line(x1, x2, y - 0.375, color, 0.75)
        stroke_line(x1, x2, y - 1.875, color, 0.75)
      end

      def rule_at_cursor(color, line_width = 0.75, from: 0, to: pdf.bounds.width)
        stroke_line(from, to, pdf.cursor, color, line_width)
      end

      # ---- Logo ----------------------------------------------------------------

      def logo?
        logo_dimensions.present?
      end

      def logo_dimensions
        return @logo_dimensions if defined?(@logo_dimensions)

        @logo_dimensions = if @logo.present?
          _object, info = pdf.build_image_object(StringIO.new(@logo))
          [ info.width.to_f, info.height.to_f ]
        end
      rescue StandardError => e
        Rails.logger.warn("Invoice logo could not be drawn: #{e.class}: #{e.message}")
        @logo_dimensions = nil
      end

      # Largest size that fits the box without distorting the logo.
      def logo_fit(max_width, max_height)
        width, height = logo_dimensions
        scale = [ max_width / width, max_height / height ].min
        [ width * scale, height * scale ]
      end

      def draw_logo(x, top, width, height)
        pdf.image StringIO.new(@logo), at: [ x, top ], width: width, height: height
      end

      def monogram(x, top, size, font_size:, fill: nil, color: style.on_accent, border: nil, round: false, radius: 0,
                   family: body_font, font_style: :bold, spacing: 0)
        if round
          if fill
            pdf.fill_color fill
            pdf.fill_circle([ x + (size / 2), top - (size / 2) ], size / 2)
          end
          if border
            pdf.stroke_color border
            pdf.line_width 1.5
            pdf.stroke_circle([ x + (size / 2), top - (size / 2) ], (size / 2) - 0.75)
          end
        else
          fill_box(x, top, size, size, fill, radius: radius) if fill
          stroke_box(x + 0.5, top - 0.5, size - 1, size - 1, border, line_width: 1.1, radius: radius) if border
        end
        pdf.font(family, style: font_style, size: font_size) do
          pdf.fill_color color
          pdf.character_spacing(spacing) do
            pdf.text_box data.initials, at: [ x, top ], width: size, height: size, align: :center, valign: :center,
                                        size: font_size, overflow: :shrink_to_fit
          end
        end
      end

      # ---- Line table helpers ------------------------------------------------

      def item_column?
        style.show_item_column && data.item_names?
      end

      def date_column?
        data.service_dates?
      end

      # Column x offsets for widths separated by gap, starting at inset.
      def column_layout(cols, inset: 0, gap: 0)
        x = inset
        cols.map do |col|
          start = x
          x += col.width + gap
          [ col, start ]
        end
      end

      # Fill the one flexible column (width nil) with the remaining space.
      def resolve_columns(cols, total_width:, inset:, gap:)
        fixed = cols.sum { |col| col.width.to_f }
        flexible = total_width - (inset * 2) - fixed - (gap * (cols.size - 1))
        cols.map { |col| col.width ? col : col.dup.tap { |copy| copy.width = flexible } }
      end

      def line_value(line, key)
        case key
        when :number then (data.lines.index(line).to_i + 1).to_s
        when :item then line["item_name"].to_s
        when :description then line["description"].to_s
        when :date then data.line_date(line).to_s
        when :quantity then data.quantity(line["quantity"])
        when :rate then data.money(line["rate"])
        when :amount then data.money(line["amount"])
        end
      end

      # Draws one row of cells at the cursor; returns nothing, moves the cursor
      # below the row. cell_styles maps a column key to text options.
      def draw_cells(line, layout, padding:, cell_styles: {}, default: {})
        pdf.move_down(padding)
        entries = layout.map do |col, x|
          options = default.merge(cell_styles.fetch(col.key, {}))
          content = options.delete(:content) || ->(row) { line_value(row, col.key) }
          column(x, col.width) { text(content.call(line), align: col.align || :left, **options) }
        end
        columns_row(entries)
        pdf.move_down(padding)
      end

      def draw_header_cells(layout, padding_top:, padding_bottom:, **options)
        pdf.move_down(padding_top)
        columns_row(layout.map { |col, x| column(x, col.width) { text(col.label, align: col.align || :left, **options) } })
        pdf.move_down(padding_bottom)
      end

      # ---- Totals ----------------------------------------------------------------

      def total_rows
        rows = [ [ "Subtotal", data.money(data.subtotal) ] ]
        rows << [ data.discount_label, data.discount_amount ] if data.discount?
        rows
      end

      def label_value(label, value, x:, width:, label_options: {}, value_options: {})
        columns_row([
          column(x, width * 0.6) { text(label, **label_options) },
          column(x + (width * 0.4), width * 0.6) { text(value, align: :right, **value_options) }
        ])
      end
    end
  end
end
