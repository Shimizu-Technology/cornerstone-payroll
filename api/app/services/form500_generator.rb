# frozen_string_literal: true

require "bigdecimal"
require "combine_pdf"
require "prawn"

class Form500Generator
  class TemplateUnavailableError < StandardError; end

  TEMPLATE_PATH = Rails.root.join("lib/assets/form500_template.pdf")

  QUARTER_LABELS = {
    1 => "1st Quarter",
    2 => "2nd Quarter",
    3 => "3rd Quarter",
    4 => "4th Quarter"
  }.freeze

  TAX_TYPE_FIELDS = [
    [ :income_tax_withholding_on_wages, "Income tax withholding on wages" ],
    [ :tax_withholding_30_percent, "30% tax withholding on certain persons" ],
    [ :corporate_estimated_tax, "Corporate estimated tax" ],
    [ :income_tax_withholding_1099, "Income tax withholding on Form 1099s" ]
  ].freeze

  DEFAULT_CHECKBOXES = {
    income_tax_withholding_on_wages: true,
    tax_withholding_30_percent: false,
    corporate_estimated_tax: false,
    income_tax_withholding_1099: false
  }.freeze

  FIELD_RECTS = {
    total_taxes_dollars: [
      [ 92.5432, 529.952, 174.536, 543.931 ],
      [ 92.3689, 331.805, 174.361, 345.785 ],
      [ 79.5310, 132.800, 161.523, 146.779 ]
    ],
    total_taxes_cents: [
      [ 175.753, 529.952, 200.880, 543.931 ],
      [ 175.579, 331.805, 200.706, 345.785 ],
      [ 162.741, 132.800, 187.868, 146.779 ]
    ],
    employer_identification_number_prefix: [
      [ 53.3741, 507.754, 72.7904, 521.079 ],
      [ 53.6909, 310.056, 73.1072, 323.380 ],
      [ 53.5906, 111.085, 73.0069, 124.410 ]
    ],
    employer_identification_number_suffix: [
      [ 76.1991, 507.754, 154.626, 521.079 ],
      [ 76.5159, 310.056, 154.942, 323.380 ],
      [ 76.4156, 111.085, 154.842, 124.410 ]
    ],
    employer_name_and_address: [
      [ 36.3825, 444.674, 425.085, 477.008 ],
      [ 36.6993, 246.975, 411.992, 279.309 ],
      [ 36.5990, 48.0049, 411.892, 80.3388 ]
    ],
    tax_year_digits: [
      [
        [ 435.723, 540.583, 447.144, 555.812 ],
        [ 446.987, 540.583, 458.408, 555.812 ],
        [ 458.251, 540.583, 469.672, 555.812 ],
        [ 469.514, 540.583, 480.936, 555.812 ]
      ],
      [
        [ 421.039, 341.884, 432.461, 357.113 ],
        [ 434.303, 341.884, 445.725, 357.113 ],
        [ 447.567, 341.884, 458.989, 357.113 ],
        [ 460.831, 341.884, 472.253, 357.113 ]
      ],
      [
        [ 420.939, 142.914, 432.360, 158.142 ],
        [ 434.203, 142.914, 445.624, 158.142 ],
        [ 447.467, 142.914, 458.888, 158.142 ],
        [ 459.731, 142.914, 471.152, 158.142 ]
      ]
    ],
    income_tax_withholding_on_wages: [
      [ 87.2511, 499.016, 95.3485, 507.391 ],
      [ 87.5679, 301.317, 95.6653, 309.693 ],
      [ 86.4676, 102.347, 94.5650, 110.722 ]
    ],
    tax_withholding_30_percent: [
      [ 87.6318, 489.117, 95.7292, 497.493 ],
      [ 87.5679, 291.418, 95.6653, 299.794 ],
      [ 86.8483, 91.4481, 94.9457, 99.8238 ]
    ],
    corporate_estimated_tax: [
      [ 249.410, 497.707, 257.507, 506.082 ],
      [ 239.726, 299.008, 247.824, 307.384 ],
      [ 244.626, 102.038, 252.723, 110.413 ]
    ],
    income_tax_withholding_1099: [
      [ 249.696, 488.904, 257.794, 497.279 ],
      [ 240.013, 290.205, 248.110, 298.581 ],
      [ 244.913, 91.2346, 253.010, 99.6104 ]
    ],
    quarter_1: [
      [ 448.098, 505.055, 456.474, 512.289 ],
      [ 431.415, 306.356, 439.791, 313.590 ],
      [ 431.315, 107.386, 439.691, 114.620 ]
    ],
    quarter_2: [
      [ 448.098, 495.268, 456.474, 502.502 ],
      [ 431.415, 296.569, 439.791, 303.803 ],
      [ 431.315, 97.5993, 439.691, 104.833 ]
    ],
    quarter_3: [
      [ 448.098, 485.482, 456.474, 492.715 ],
      [ 431.415, 287.783, 439.791, 295.016 ],
      [ 431.315, 88.8125, 439.691, 96.0460 ]
    ],
    quarter_4: [
      [ 448.098, 475.695, 456.474, 482.928 ],
      [ 431.415, 277.996, 439.791, 285.229 ],
      [ 431.315, 79.0257, 439.691, 86.2592 ]
    ]
  }.freeze

  def self.default_fields(company:, pay_period: nil)
    fit_total = if pay_period
      pay_period.payroll_items.not_voided
        .sum("withholding_tax + COALESCE(additional_withholding, 0)").to_f
    else
      0.0
    end

    quarter = if pay_period&.pay_date
      ((pay_period.pay_date.month - 1) / 3) + 1
    else
      ((Date.current.month - 1) / 3) + 1
    end

    year = pay_period&.pay_date&.year || Date.current.year
    dollars, cents = amount_parts(fit_total)

    {
      pay_period_id: pay_period&.id,
      company_name: company.name.to_s.squish,
      company_address_line1: company.address_line1.to_s.squish,
      company_address_line2: company.address_line2.to_s.squish,
      company_city: company.city.to_s.squish,
      company_state: company.state.to_s.squish,
      company_zip: company.zip.to_s.squish,
      employer_identification_number: company.ein.to_s.squish,
      total_taxes_dollars: dollars,
      total_taxes_cents: cents,
      tax_year: year.to_s,
      tax_period_quarter: quarter,
      notes: pay_period&.period_description.to_s,
      pay_date: pay_period&.pay_date&.iso8601,
      period_label: pay_period&.period_description.to_s,
      **DEFAULT_CHECKBOXES
    }
  end

  def initialize(fields:)
    @fields = DEFAULT_CHECKBOXES.merge(fields.deep_symbolize_keys)
  end

  def generate
    template = load_template!
    overlay = CombinePDF.parse(build_overlay_pdf)
    raise TemplateUnavailableError, "Form 500 overlay could not be generated" if overlay.pages.blank?

    template.pages[0] << overlay.pages[0]
    template.to_pdf
  end

  private

  attr_reader :fields

  def load_template!
    template = CombinePDF.load(TEMPLATE_PATH.to_s)
    raise TemplateUnavailableError, "Form 500 template is unavailable" if template.pages.blank?

    template
  rescue StandardError => e
    raise TemplateUnavailableError, "Form 500 template is unavailable" if template_load_error?(e)

    raise
  end

  def template_load_error?(error)
    return true if error.is_a?(Errno::ENOENT)
    return true if error.class.name.start_with?("CombinePDF::")

    false
  end

  def build_overlay_pdf
    pdf = Prawn::Document.new(page_size: "LETTER", margin: 0)
    pdf.font("Helvetica")

    3.times do |copy_index|
      draw_text_box(pdf, FIELD_RECTS[:total_taxes_dollars][copy_index], formatted_dollars, size: 11, align: :center)
      draw_text_box(pdf, FIELD_RECTS[:total_taxes_cents][copy_index], formatted_cents, size: 11, align: :center)
      draw_text_box(pdf, FIELD_RECTS[:employer_identification_number_prefix][copy_index], ein_prefix, size: 10, align: :center)
      draw_text_box(pdf, FIELD_RECTS[:employer_identification_number_suffix][copy_index], ein_suffix, size: 10, align: :center)
      draw_text_box(pdf, FIELD_RECTS[:employer_name_and_address][copy_index], employer_block, size: 8.5, valign: :center, leading: 1.0)

      FIELD_RECTS[:tax_year_digits][copy_index].each_with_index do |rect, idx|
        draw_text_box(pdf, rect, tax_year_digits[idx], size: 10, align: :center, valign: :center)
      end

      draw_checkbox(pdf, FIELD_RECTS[:income_tax_withholding_on_wages][copy_index], truthy?(fields[:income_tax_withholding_on_wages]))
      draw_checkbox(pdf, FIELD_RECTS[:tax_withholding_30_percent][copy_index], truthy?(fields[:tax_withholding_30_percent]))
      draw_checkbox(pdf, FIELD_RECTS[:corporate_estimated_tax][copy_index], truthy?(fields[:corporate_estimated_tax]))
      draw_checkbox(pdf, FIELD_RECTS[:income_tax_withholding_1099][copy_index], truthy?(fields[:income_tax_withholding_1099]))

      draw_checkbox(pdf, FIELD_RECTS[:quarter_1][copy_index], quarter_value == 1)
      draw_checkbox(pdf, FIELD_RECTS[:quarter_2][copy_index], quarter_value == 2)
      draw_checkbox(pdf, FIELD_RECTS[:quarter_3][copy_index], quarter_value == 3)
      draw_checkbox(pdf, FIELD_RECTS[:quarter_4][copy_index], quarter_value == 4)
    end

    pdf.render
  end

  def draw_text_box(pdf, rect, content, size:, align: :left, valign: :center, leading: 0)
    return if content.blank?

    left, bottom, right, top = normalize_rect(rect)
    pdf.fill_color "000000"
    pdf.text_box(
      content.to_s,
      at: [ left + 2, top - 1 ],
      width: (right - left) - 4,
      height: (top - bottom),
      size: size,
      align: align,
      valign: valign,
      leading: leading,
      overflow: :shrink_to_fit,
      min_font_size: [ size - 2, 6 ].max
    )
  end

  def draw_checkbox(pdf, rect, checked)
    return unless checked

    left, bottom, right, top = normalize_rect(rect)
    pdf.fill_color "000000"
    pdf.font("Helvetica-Bold") do
      pdf.draw_text("X", at: [ left + 1.0, bottom + 0.4 ], size: 11)
    end
  end

  def normalize_rect(rect)
    left, first_y, right, second_y = rect
    [ left, [ first_y, second_y ].min, right, [ first_y, second_y ].max ]
  end

  def employer_block
    employer_block_lines.join("\n")
  end

  def normalized_company_name
    fields[:company_name].to_s.upcase.presence
  end

  def employer_block_lines
    lines = []
    lines << normalized_company_name if normalized_company_name.present?

    lines.concat(compose_address_lines)

    return lines.first(3) if lines.length <= 3

    [ lines[0], lines[1], lines[2..].join(" ") ]
  end

  def compose_address_lines
    primary_line = normalized_address_line(fields[:company_address_line1])
    continuation_parts = [
      normalized_address_line(fields[:company_address_line2]),
      company_locality_line
    ].compact_blank

    continuation_text = continuation_parts.join(", ")
    packed_lines = []
    packed_lines << primary_line if primary_line.present?

    if continuation_text.present?
      remaining_lines = primary_line.present? ? 2 : 3
      packed_lines.concat(wrap_text(continuation_text, max_characters: 56, max_lines: remaining_lines))
    end

    packed_lines.first(3)
  end

  def normalized_address_line(value)
    value.to_s.split(/\r?\n/).map { |line| line.squish }.reject(&:blank?).join(", ").presence
  end

  def wrap_text(text, max_characters:, max_lines: nil)
    return [] if text.blank?

    lines = [ "" ]

    text.split(/\s+/).each do |word|
      current = lines.last
      candidate = current.blank? ? word : "#{current} #{word}"

      if candidate.length <= max_characters
        lines[-1] = candidate
      elsif max_lines.present? && lines.length >= max_lines
        lines[-1] = "#{lines[-1]} #{word}".strip
      else
        lines << word
      end
    end

    lines.map(&:strip).reject(&:blank?)
  end

  def company_locality_line
    locality = [ fields[:company_city].to_s.squish.presence, fields[:company_state].to_s.squish.presence ]
      .compact_blank
      .join(", ")

    [ locality.presence, fields[:company_zip].to_s.squish.presence ].compact_blank.join(" ").presence
  end

  def formatted_dollars
    fields[:total_taxes_dollars].presence || "0"
  end

  def formatted_cents
    (fields[:total_taxes_cents].presence || "00").to_s.rjust(2, "0")
  end

  def tax_year_digits
    (fields[:tax_year].presence || Date.current.year.to_s).to_s.gsub(/\D/, "").rjust(4, "0").last(4).chars
  end

  def quarter_value
    fields[:tax_period_quarter].to_i.clamp(1, 4)
  end

  def ein_prefix
    digits = normalized_ein_digits
    return "" if digits.blank?

    digits[0, 2]
  end

  def ein_suffix
    digits = normalized_ein_digits
    return "" if digits.blank?

    digits[2, 7]
  end

  def normalized_ein_digits
    @normalized_ein_digits ||= fields[:employer_identification_number].to_s.gsub(/\D/, "")
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def self.amount_parts(amount)
    value = BigDecimal(amount.to_s).round(2)
    whole = value.truncate.to_i
    cents = ((value - value.truncate) * 100).to_i
    [ whole.to_s, cents.to_s.rjust(2, "0") ]
  end
end
