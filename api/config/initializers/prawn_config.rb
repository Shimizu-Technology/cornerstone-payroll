# frozen_string_literal: true

# Suppress Prawn's UTF-8 font warning — we use only ASCII-safe text in check output.
# If Unicode support is needed in the future, load a TTF font in CheckGenerator.
require "prawn"
Prawn::Fonts::AFM.hide_m17n_warning = true
