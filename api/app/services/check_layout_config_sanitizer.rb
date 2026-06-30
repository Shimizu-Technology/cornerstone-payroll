# frozen_string_literal: true

# Normalizes per-company check layout overrides so stale coordinates from one
# check stock cannot leak into another stock type. This is intentionally strict:
# only fields known to the target generator and numeric layout keys are kept.
class CheckLayoutConfigSanitizer
  ALLOWED_FIELD_KEYS = %w[x y width height font_size].freeze

  def self.call(stock_type:, config:)
    new(stock_type: stock_type, config: config).call
  end

  def initialize(stock_type:, config:)
    @stock_type = stock_type.to_s
    @config = normalize_layout_numeric_values(config || {})
  end

  def call
    return {} unless @config.is_a?(Hash)

    first_hawaiian_4up? ? sanitize_first_hawaiian_layout_config : sanitize_standard_check_layout_config
  end

  private

  attr_reader :stock_type, :config

  def first_hawaiian_4up?
    stock_type == "first_hawaiian_4up"
  end

  def sanitize_first_hawaiian_layout_config
    sanitize_nested_field_layout_config(
      config,
      FirstHawaiianFourUpCheckGenerator.default_layout_config,
      max_y: FirstHawaiianFourUpCheckGenerator::SLOT_HEIGHT
    )
  end

  def sanitize_standard_check_layout_config
    defaults = CheckGenerator.default_layout_config
    sanitized = sanitize_nested_field_layout_config(
      config,
      { "check_face" => defaults.fetch("check_face") },
      max_y: CheckGenerator::SECTION_HEIGHT
    )

    stub_config = config["stub"]
    if stub_config.is_a?(Hash)
      allowed_stub_keys = defaults.fetch("stub").keys
      clean_stub = stub_config.slice(*allowed_stub_keys).select { |_key, value| value.is_a?(Numeric) }
      sanitized["stub"] = clean_stub if clean_stub.present?
    end

    sanitized
  end

  def sanitize_nested_field_layout_config(source_config, defaults, max_y:)
    defaults.each_with_object({}) do |(section, field_defaults), sanitized|
      section_config = source_config[section]
      next unless section_config.is_a?(Hash)

      field_defaults.each_key do |field|
        field_config = section_config[field]
        next unless field_config.is_a?(Hash)

        clean_field = field_config.slice(*ALLOWED_FIELD_KEYS).select { |_key, value| value.is_a?(Numeric) }
        next if clean_field.empty?
        next if layout_field_position_out_of_bounds?(clean_field, max_y: max_y)

        sanitized[section] ||= {}
        sanitized[section][field] = clean_field
      end
    end
  end

  def layout_field_position_out_of_bounds?(field_config, max_y:)
    x = field_config["x"]
    y = field_config["y"]

    return true if x.present? && (x.to_f < -36.0 || x.to_f > 612.0)
    return true if y.present? && (y.to_f < -36.0 || y.to_f > max_y.to_f)

    false
  end

  def normalize_layout_numeric_values(value)
    if defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)
      return normalize_layout_numeric_values(value.to_unsafe_h)
    end

    case value
    when Hash
      value.each_with_object({}) do |(key, nested), normalized|
        normalized[key.to_s] = normalize_layout_numeric_values(nested)
      end
    when Array
      value.map { |nested| normalize_layout_numeric_values(nested) }
    when String
      value.match?(/\A-?\d+(\.\d+)?\z/) ? value.to_f : value
    else
      value
    end
  end
end
