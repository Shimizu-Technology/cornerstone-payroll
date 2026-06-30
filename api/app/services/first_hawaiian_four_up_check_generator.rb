# frozen_string_literal: true

require "prawn"
require "active_support/number_helper"
require_relative "../../lib/number_to_words"

# Generates variable-data overlays for First Hawaiian Bank 4-up check stock.
#
# The physical sheet already contains the company identity, bank marks, MICR
# line, check numbers, and left register boxes. This generator prints only the
# fields that change per check and packs four checks on each letter-size page.
class FirstHawaiianFourUpCheckGenerator
  PAGE_WIDTH = 612.0
  PAGE_HEIGHT = 792.0
  SLOT_COUNT = 4
  SLOT_HEIGHT = PAGE_HEIGHT / SLOT_COUNT
  MAX_SLOT_PITCH_ADJUSTMENT = 36.0
  MIN_SLOT_PITCH_ADJUSTMENT = -36.0
  MARGIN = 0.0

  DEFAULT_LAYOUT = {
    check_face: {
      date: { x: 495.0, y: 162.0, width: 86.0, font_size: 8.5 },
      payee: { x: 240.0, y: 129.0, width: 216.0, font_size: 9.0 },
      amount: { x: 486.0, y: 134.0, width: 78.0, font_size: 9.0 },
      amount_words: { x: 194.0, y: 106.0, width: 382.0, font_size: 8.0 },
      memo: { x: 214.0, y: 58.0, width: 152.0, font_size: 7.0 }
    },
    register: {
      date: { x: 64.0, y: 154.0, width: 92.0, font_size: 7.0 },
      payee: { x: 66.0, y: 134.0, width: 90.0, font_size: 7.0 },
      memo: { x: 66.0, y: 114.0, width: 90.0, font_size: 7.0 },
      amount: { x: 98.0, y: 64.0, width: 58.0, font_size: 7.0 }
    }
  }.freeze

  Entry = Struct.new(
    :check_number,
    :payee,
    :amount,
    :date,
    :memo,
    :voided,
    keyword_init: true
  )

  attr_reader :company, :entries, :starting_slot

  def self.default_layout_config
    stringify_layout(DEFAULT_LAYOUT)
  end

  def self.resolved_layout_for(company)
    deep_merge(default_layout_config, stringify_layout(company.check_layout_config || {}))
  end

  def self.page_layout_metadata(company)
    slot_pitch_adjustment = slot_pitch_adjustment_for(company)
    {
      width: PAGE_WIDTH,
      height: PAGE_HEIGHT,
      slot_count: SLOT_COUNT,
      slot_height: SLOT_HEIGHT,
      slot_pitch: SLOT_HEIGHT + slot_pitch_adjustment,
      slot_pitch_adjustment: slot_pitch_adjustment,
      preview_slot_bottom: PAGE_HEIGHT - SLOT_HEIGHT,
      offset_x_points: (company.check_offset_x.to_f * 72).round(1),
      offset_y_points: (company.check_offset_y.to_f * 72).round(1)
    }
  end

  def self.slot_pitch_adjustment_for(company)
    config = stringify_layout(company.check_layout_config || {})
    raw_value = config.dig("calibration", "slot_pitch_adjustment")
    numeric_value = if raw_value.is_a?(Numeric)
      raw_value.to_f
    elsif raw_value.is_a?(String) && raw_value.match?(/\A-?\d+(\.\d+)?\z/)
      raw_value.to_f
    end
    return 0.0 unless numeric_value

    numeric_value.clamp(MIN_SLOT_PITCH_ADJUSTMENT, MAX_SLOT_PITCH_ADJUSTMENT)
  end

  def initialize(company:, payroll_items: [], non_employee_checks: [], starting_slot: 1)
    @company = company
    @entries = payroll_items.map { |item| entry_from_payroll_item(item) } +
      non_employee_checks.map { |check| entry_from_non_employee_check(check) }
    @starting_slot = normalize_starting_slot(starting_slot)
  end

  def generate
    raise ArgumentError, "No check entries to render" if entries.empty?

    Prawn::Document.new(page_size: [ PAGE_WIDTH, PAGE_HEIGHT ], page_layout: :portrait, margin: MARGIN) do |pdf|
      draw_entries(pdf)
    end.render
  end

  def alignment_test
    Prawn::Document.new(page_size: [ PAGE_WIDTH, PAGE_HEIGHT ], page_layout: :portrait, margin: MARGIN) do |pdf|
      SLOT_COUNT.times do |slot_index|
        slot_bottom = slot_bottom_for(slot_index)
        draw_slot_outline(pdf, slot_bottom, "FHB CHECK SLOT #{slot_index + 1}")
        %i[date payee amount amount_words memo].each do |field|
          cfg = layout_field(:check_face, field)
          draw_marker(pdf, cfg["x"].to_f + ox, slot_bottom + cfg["y"].to_f + oy, "check.#{field}")
        end
        %i[date payee memo amount].each do |field|
          cfg = layout_field(:register, field)
          draw_marker(pdf, cfg["x"].to_f + ox, slot_bottom + cfg["y"].to_f + oy, "register.#{field}")
        end
      end
      pdf.bounding_box([ 0, PAGE_HEIGHT - 4 ], width: PAGE_WIDTH) do
        pdf.font_size(7) { pdf.text "FIRST HAWAIIAN 4-UP ALIGNMENT TEST - Print on plain paper.", align: :center, color: "CC0000" }
      end
    end.render
  end

  private

  def normalize_starting_slot(value)
    value.to_i.clamp(1, SLOT_COUNT)
  end

  def ox
    (company.check_offset_x.to_f * 72).round(1)
  end

  def oy
    (company.check_offset_y.to_f * 72).round(1)
  end

  def draw_entries(pdf)
    entry_index = 0
    slot_cursor = starting_slot - 1

    while entry_index < entries.size
      pdf.start_new_page unless entry_index.zero?

      while slot_cursor < SLOT_COUNT && entry_index < entries.size
        draw_entry(pdf, entries[entry_index], slot_bottom_for(slot_cursor))
        entry_index += 1
        slot_cursor += 1
      end

      slot_cursor = 0
    end
  end

  def draw_entry(pdf, entry, slot_bottom)
    draw_void_watermark(pdf, slot_bottom) if entry.voided

    draw_text_field(pdf, :check_face, :date, slot_bottom, format_date(entry.date), align: :right)
    draw_text_field(pdf, :check_face, :payee, slot_bottom, entry.payee)
    draw_text_field(pdf, :check_face, :amount, slot_bottom, fn(entry.amount), align: :right)
    draw_text_field(pdf, :check_face, :amount_words, slot_bottom, NumberToWords.convert(entry.amount))
    draw_text_field(pdf, :check_face, :memo, slot_bottom, entry.memo.to_s)

    draw_text_field(pdf, :register, :date, slot_bottom, format_date(entry.date))
    draw_text_field(pdf, :register, :payee, slot_bottom, entry.payee)
    draw_text_field(pdf, :register, :memo, slot_bottom, entry.memo.to_s)
    draw_text_field(pdf, :register, :amount, slot_bottom, fd(entry.amount), align: :right)
  end

  def draw_text_field(pdf, section, field, slot_bottom, text, align: :left)
    cfg = layout_field(section, field)
    pdf.bounding_box(
      [ cfg["x"].to_f + ox, slot_bottom + cfg["y"].to_f + oy ],
      width: cfg["width"].to_f,
      height: cfg.fetch("height", 14).to_f
    ) do
      pdf.font_size(cfg["font_size"].to_f) do
        pdf.text text.to_s, align:, overflow: :shrink_to_fit
      end
    end
  end

  def slot_bottom_for(slot_index)
    (PAGE_HEIGHT - SLOT_HEIGHT) - (slot_index * slot_pitch)
  end

  def slot_pitch
    SLOT_HEIGHT + slot_pitch_adjustment
  end

  def slot_pitch_adjustment
    @slot_pitch_adjustment ||= self.class.slot_pitch_adjustment_for(company)
  end

  def entry_from_payroll_item(item)
    Entry.new(
      check_number: item.check_number,
      payee: item.employee.full_name,
      amount: item.net_pay,
      date: item.check_date || item.pay_period.pay_date,
      memo: payroll_memo(item),
      voided: item.voided?
    )
  end

  def entry_from_non_employee_check(check)
    Entry.new(
      check_number: check.check_number,
      payee: check.payable_to,
      amount: check.amount,
      date: check.effective_payment_date,
      memo: check.memo.presence || check.description.presence || check.check_type.to_s.titleize,
      voided: check.voided?
    )
  end

  def payroll_memo(item)
    return item.check_memo if item.check_memo.present?

    period = item.pay_period
    template = company&.check_memo_template.presence
    return "Payroll #{format_date(period.start_date)} - #{format_date(period.end_date)}" unless template

    employee = item.employee
    template
      .gsub("{employee_name}", employee.full_name)
      .gsub("{employee_first_name}", employee.first_name.to_s)
      .gsub("{employee_last_name}", employee.last_name.to_s)
      .gsub("{period_start}", format_date(period.start_date))
      .gsub("{period_end}", format_date(period.end_date))
      .gsub("{pay_date}", format_date(period.pay_date))
      .gsub("{check_number}", item.check_number.to_s)
      .gsub("{company_name}", company&.name.to_s)
  end

  def layout_field(section, field)
    default = default_layout_config.fetch(section.to_s).fetch(field.to_s)
    section_config = layout_config[section.to_s]
    configured = section_config[field.to_s] if section_config.is_a?(Hash)
    return default unless configured.is_a?(Hash)

    default.merge(configured)
  end

  def layout_config
    @layout_config ||= self.class.resolved_layout_for(company)
  end

  def default_layout_config
    @default_layout_config ||= self.class.default_layout_config
  end

  def self.stringify_layout(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, nested), acc| acc[key.to_s] = stringify_layout(nested) }
    when Array
      value.map { |entry| stringify_layout(entry) }
    else
      value
    end
  end

  def stringify_layout(value)
    self.class.stringify_layout(value)
  end

  def self.deep_merge(base, overrides)
    base.merge(overrides) do |_key, old_value, new_value|
      old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
    end
  end

  def deep_merge(base, overrides)
    self.class.deep_merge(base, overrides)
  end

  def draw_slot_outline(pdf, slot_bottom, label)
    pdf.stroke_color "0000AA"
    pdf.line_width 0.5
    pdf.stroke_rectangle [ 12 + ox, slot_bottom + SLOT_HEIGHT - 6 + oy ], PAGE_WIDTH - 24, SLOT_HEIGHT - 12
    pdf.font_size(8) { pdf.draw_text label, at: [ PAGE_WIDTH / 2 - 42, slot_bottom + SLOT_HEIGHT - 18 + oy ], style: :bold }
    pdf.stroke_color "000000"
  end

  def draw_marker(pdf, x, y, label)
    pdf.save_graphics_state do
      pdf.stroke_color "CC0000"
      pdf.fill_color "CC0000"
      pdf.line_width 0.4
      pdf.stroke_line [ x - 5, y ], [ x + 5, y ]
      pdf.stroke_line [ x, y - 5 ], [ x, y + 5 ]
      pdf.font_size(5.5) { pdf.draw_text label, at: [ x + 7, y + 2 ] }
    end
  end

  def draw_void_watermark(pdf, slot_bottom)
    cx = PAGE_WIDTH / 2
    cy = slot_bottom + SLOT_HEIGHT / 2
    pdf.save_graphics_state do
      pdf.fill_color "FFCCCC"
      pdf.transparent(0.25) do
        pdf.font_size(58) do
          pdf.rotate(20, origin: [ cx, cy ]) do
            pdf.draw_text "VOID", at: [ cx - 78, cy - 20 ], style: :bold
          end
        end
      end
    end
  end

  def fn(value)
    ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value.to_f))
  end

  def fd(value)
    "$#{fn(value)}"
  end

  def format_date(date)
    date&.strftime("%m/%d/%Y") || "N/A"
  end
end
