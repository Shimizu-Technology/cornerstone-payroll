# frozen_string_literal: true

require "combine_pdf"
require "prawn"

class OfficialPdfOverlay
  class TemplateUnavailableError < StandardError; end

  def initialize(template_path:, page_sizes:)
    @template_path = template_path
    @page_sizes = page_sizes
  end

  def generate(page_count: nil)
    template = load_template!
    overlay = CombinePDF.parse(build_overlay_pdf(page_count || template.pages.length))
    output = CombinePDF.new

    (page_count || template.pages.length).times do |index|
      base_page = template.pages[index] || template.pages[0]
      output << base_page
      output.pages[index] << overlay.pages[index]
    end

    output.to_pdf
  end

  private

  attr_reader :template_path, :page_sizes

  def load_template!
    template = CombinePDF.load(template_path.to_s)
    raise TemplateUnavailableError, "PDF template is unavailable" if template.pages.blank?

    template
  rescue StandardError => e
    raise TemplateUnavailableError, "PDF template is unavailable" if template_load_error?(e)

    raise
  end

  def template_load_error?(error)
    error.is_a?(Errno::ENOENT) || error.class.name.start_with?("CombinePDF::")
  end

  def build_overlay_pdf(page_count)
    first_size = page_sizes.fetch(0)
    pdf = Prawn::Document.new(page_size: first_size, margin: 0)
    pdf.font("Helvetica")

    page_count.times do |index|
      pdf.start_new_page(page_size: page_sizes.fetch(index, page_sizes.first), margin: 0) if index.positive?
      draw_page(pdf, index + 1)
      draw_document_status(pdf, index + 1)
    end

    pdf.render
  end

  def draw_page(_pdf, _page_number)
    raise NotImplementedError
  end

  def draw_document_status(_pdf, _page_number)
    # Optional hook for overlays that need a visible review/filing status.
  end

  def draw_text_box(pdf, rect, content, size: 9, align: :left, valign: :center, leading: 0, min_font_size: nil)
    return if blank_value?(content)

    left, bottom, right, top = normalize_rect(rect)
    pdf.fill_color "000000"
    pdf.text_box(
      content.to_s,
      at: [ left + 1.5, top - 1 ],
      width: [ (right - left) - 3, 1 ].max,
      height: [ top - bottom, 1 ].max,
      size: size,
      align: align,
      valign: valign,
      leading: leading,
      overflow: :shrink_to_fit,
      min_font_size: min_font_size || [ size - 2, 5 ].max
    )
  end

  def draw_checkbox(pdf, rect, checked)
    return unless checked

    left, bottom, _right, _top = normalize_rect(rect)
    pdf.fill_color "000000"
    pdf.font("Helvetica-Bold") do
      pdf.draw_text("X", at: [ left + 1.0, bottom + 0.2 ], size: 10)
    end
  end

  def normalize_rect(rect)
    left, y1, right, y2 = rect
    [ left, [ y1, y2 ].min, right, [ y1, y2 ].max ]
  end

  def split_rect_horizontally(rect, count, gap: 0.0)
    left, bottom, right, top = normalize_rect(rect)
    width = ((right - left) - (gap * (count - 1))) / count.to_f

    count.times.map do |index|
      item_left = left + (index * (width + gap))
      [ item_left, bottom, item_left + width, top ]
    end
  end

  def blank_value?(value)
    value.nil? || value.to_s.strip.empty?
  end

  def money_parts(value)
    return [ nil, nil ] if blank_value?(value)

    amount = BigDecimal(value.to_s).round(2)
    dollars = amount.truncate.to_i
    cents = ((amount - amount.truncate) * 100).abs.to_i
    [ dollars.to_s, cents.to_s.rjust(2, "0") ]
  end

  def money_string(value)
    return nil if blank_value?(value)

    format("%.2f", BigDecimal(value.to_s).round(2))
  end

  def date_string(value)
    return nil if blank_value?(value)

    date = value.is_a?(Date) ? value : Date.parse(value.to_s)
    date.strftime("%m/%d/%Y")
  rescue ArgumentError
    value.to_s
  end

  def ein_parts(ein)
    digits = ein.to_s.gsub(/\D/, "")
    [ digits[0, 2], digits[2, 7] ]
  end

  def ein_digits(ein)
    ein.to_s.gsub(/\D/, "").rjust(9, "0").last(9).chars
  end
end
