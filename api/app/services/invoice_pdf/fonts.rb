# frozen_string_literal: true

module InvoicePdf
  # Registers the vendored OFL theme fonts on a Prawn document.
  #
  # Every family exposes the same style names (normal, italic, light, medium,
  # semibold, semibold_italic, bold, bold_italic, extrabold), mapped to the
  # nearest vendored weight, so a renderer can ask for any of them. If a font
  # file is missing or unreadable the family falls back to the built-in
  # Liberation Sans, and the invoice still renders. Characters a theme font
  # lacks fall back to Liberation Sans glyph by glyph.
  module Fonts
    FALLBACK = PdfUnicodeFont::FAMILY
    DIR = Rails.root.join("vendor/fonts")
    STYLE_NAMES = %i[normal italic light medium semibold semibold_italic bold bold_italic extrabold].freeze

    FAMILIES = {
      "Inter" => {
        normal: "inter/Inter_400Regular.ttf",
        italic: "inter/Inter_400Regular_Italic.ttf",
        light: "inter/Inter_300Light.ttf",
        medium: "inter/Inter_500Medium.ttf",
        semibold: "inter/Inter_600SemiBold.ttf",
        bold: "inter/Inter_700Bold.ttf"
      },
      "SpaceGrotesk" => {
        normal: "space-grotesk/SpaceGrotesk_500Medium.ttf",
        medium: "space-grotesk/SpaceGrotesk_500Medium.ttf",
        semibold: "space-grotesk/SpaceGrotesk_600SemiBold.ttf",
        bold: "space-grotesk/SpaceGrotesk_700Bold.ttf"
      },
      "SourceSerif4" => {
        normal: "source-serif-4/SourceSerif4_400Regular.ttf",
        italic: "source-serif-4/SourceSerif4_400Regular_Italic.ttf",
        semibold: "source-serif-4/SourceSerif4_600SemiBold.ttf",
        semibold_italic: "source-serif-4/SourceSerif4_600SemiBold_Italic.ttf",
        bold: "source-serif-4/SourceSerif4_700Bold.ttf"
      },
      "SourceSans3" => {
        normal: "source-sans-3/SourceSans3_400Regular.ttf",
        italic: "source-sans-3/SourceSans3_400Regular_Italic.ttf",
        semibold: "source-sans-3/SourceSans3_600SemiBold.ttf",
        bold: "source-sans-3/SourceSans3_700Bold.ttf"
      },
      "Manrope" => {
        normal: "manrope/Manrope_400Regular.ttf",
        medium: "manrope/Manrope_500Medium.ttf",
        semibold: "manrope/Manrope_600SemiBold.ttf",
        bold: "manrope/Manrope_700Bold.ttf",
        extrabold: "manrope/Manrope_800ExtraBold.ttf"
      }
    }.freeze

    # Nearest available weight when a family lacks a style.
    SUBSTITUTES = {
      italic: %i[normal],
      light: %i[normal],
      medium: %i[normal],
      semibold: %i[bold medium normal],
      semibold_italic: %i[italic semibold normal],
      bold: %i[semibold normal],
      bold_italic: %i[semibold_italic italic bold normal],
      extrabold: %i[bold semibold normal]
    }.freeze

    module_function

    def register!(pdf, families)
      complete_fallback_family!(pdf)
      families.uniq.each do |family|
        pdf.font_families[family] = available?(family) ? styles_for(family) : pdf.font_families[FALLBACK]
      end
      pdf.fallback_fonts([ FALLBACK ])
      pdf
    end

    # Liberation Sans has four faces; the extra style names point at them.
    def complete_fallback_family!(pdf)
      base = pdf.font_families[FALLBACK]
      pdf.font_families[FALLBACK] = base.merge(
        light: base[:normal], medium: base[:normal], semibold: base[:bold],
        semibold_italic: base[:bold_italic], extrabold: base[:bold]
      )
    end

    def styles_for(family)
      paths = FAMILIES.fetch(family).transform_values { |file| DIR.join(file).to_s }
      STYLE_NAMES.to_h do |style|
        key = ([ style ] + SUBSTITUTES.fetch(style, [])).find { |candidate| paths[candidate] } || :normal
        [ style, paths.fetch(key) ]
      end
    end

    # Each family is checked once per process: every file must exist and parse.
    def available?(family)
      @available ||= {}
      return @available[family] if @available.key?(family)

      @available[family] = FAMILIES.key?(family) && FAMILIES.fetch(family).values.uniq.all? do |file|
        TTFunk::File.open(DIR.join(file).to_s).name.font_name.present?
      end
    rescue StandardError => e
      Rails.logger.warn("Invoice font #{family} unavailable, using #{FALLBACK}: #{e.class}: #{e.message}")
      @available[family] = false
    end

    def reset!
      @available = nil
    end
  end
end
