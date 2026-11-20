# frozen_string_literal: true

module InvoicePdf
  # The look of one invoice PDF: theme, brand color, logo size and the
  # show/hide switches a billing profile controls.
  #
  # Issued invoices are evidence, so the style is copied into the issued
  # snapshot (see Invoice#build_snapshot) with the accent already resolved.
  # A later re-render from that snapshot reproduces the same look even if the
  # profile or a theme's default color changes. A snapshot without a "style"
  # key predates themes and renders with the legacy layout.
  class Style
    VERSION = 1
    THEMES = %w[classic modern professional banner].freeze
    LEGACY = "legacy"
    LOGO_SIZES = %w[small medium large].freeze
    DEFAULT_LOGO_SIZE = "medium"
    DEFAULT_THEME = "classic"
    HEX_COLOR = /\A#[0-9A-F]{6}\z/
    DEFAULT_ACCENTS = {
      "classic" => "#1F4E79",
      "modern" => "#0F766E",
      "professional" => "#6B2737",
      "banner" => "#1E40AF"
    }.freeze
    TOGGLES = %w[show_service_period show_item_column show_how_to_pay].freeze

    # WCAG 2 AA for normal-size text.
    MIN_CONTRAST = 4.5
    LIGHT_ON_ACCENT = "FFFFFF"
    DARK_ON_ACCENT = "000000"

    attr_reader :theme, :logo_size, :show_service_period, :show_item_column, :show_how_to_pay

    def self.legacy
      new(theme: LEGACY)
    end

    def self.from_profile(profile)
      new(
        theme: profile.invoice_theme,
        accent_color: profile.accent_color,
        logo_size: profile.logo_size,
        show_service_period: profile.show_service_period,
        show_item_column: profile.show_item_column,
        show_how_to_pay: profile.show_how_to_pay
      )
    end

    def self.from_snapshot(snapshot)
      data = snapshot.is_a?(Hash) ? snapshot["style"] : nil
      return legacy unless data.is_a?(Hash) && data["theme"].present?

      new(
        theme: data["theme"],
        accent_color: data["accent_color"],
        logo_size: data["logo_size"],
        show_service_period: data.fetch("show_service_period", true),
        show_item_column: data.fetch("show_item_column", true),
        show_how_to_pay: data.fetch("show_how_to_pay", true)
      )
    end

    def self.normalize_hex(value)
      text = value.to_s.strip.upcase
      return nil if text.blank?

      text = "##{text}" unless text.start_with?("#")
      text
    end

    def self.valid_hex?(value)
      value.to_s.match?(HEX_COLOR)
    end

    # Relative luminance and contrast ratio per WCAG 2.
    def self.contrast_ratio(first, second)
      lighter, darker = [ luminance(first), luminance(second) ].sort.reverse
      (lighter + 0.05) / (darker + 0.05)
    end

    def self.luminance(hex)
      channels = hex.to_s.delete("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
      red, green, blue = channels.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    end

    def initialize(theme:, accent_color: nil, logo_size: nil, show_service_period: true, show_item_column: true,
                   show_how_to_pay: true)
      @theme = theme == LEGACY ? LEGACY : (THEMES.include?(theme.to_s) ? theme.to_s : DEFAULT_THEME)
      @accent_color = self.class.normalize_hex(accent_color)
      @accent_color = nil unless self.class.valid_hex?(@accent_color)
      @logo_size = LOGO_SIZES.include?(logo_size.to_s) ? logo_size.to_s : DEFAULT_LOGO_SIZE
      boolean = ActiveModel::Type::Boolean.new
      @show_service_period = boolean.cast(show_service_period) != false
      @show_item_column = boolean.cast(show_item_column) != false
      @show_how_to_pay = boolean.cast(show_how_to_pay) != false
    end

    def legacy?
      theme == LEGACY
    end

    # "#RRGGBB", the profile's color or the theme default.
    def accent_hex
      @accent_color || DEFAULT_ACCENTS.fetch(theme, DEFAULT_ACCENTS[DEFAULT_THEME])
    end

    # Prawn colors have no leading "#".
    def accent
      accent_hex.delete("#")
    end

    # Text drawn on an accent fill (amount-due bar, banner, monogram tile):
    # white when it meets 4.5:1, otherwise black. Whenever white falls short
    # of 4.5:1 black clears it, so every accent gets readable text.
    def on_accent
      return LIGHT_ON_ACCENT if self.class.contrast_ratio(accent, LIGHT_ON_ACCENT) >= MIN_CONTRAST

      DARK_ON_ACCENT
    end

    # The accent used as text on white paper (labels, the Modern total).
    # A light accent is darkened in small steps until it reaches 4.5:1, so a
    # pale brand color still prints legible labels.
    def accent_text
      @accent_text ||= begin
        color = accent
        20.times do
          break if self.class.contrast_ratio(color, "FFFFFF") >= MIN_CONTRAST

          color = color.scan(/../).map { |pair| (pair.to_i(16) * 0.9).floor.to_s(16).rjust(2, "0") }.join.upcase
        end
        color
      end
    end

    def to_snapshot
      return nil if legacy?

      {
        "version" => VERSION,
        "theme" => theme,
        "accent_color" => accent_hex,
        "logo_size" => logo_size,
        "show_service_period" => show_service_period,
        "show_item_column" => show_item_column,
        "show_how_to_pay" => show_how_to_pay
      }
    end

    def template_version
      legacy? ? "standard-v3" : "#{theme}-v#{VERSION}"
    end
  end
end
