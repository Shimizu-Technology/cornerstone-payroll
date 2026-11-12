# frozen_string_literal: true

require "pdf/reader"

# Real-world names that Prawn's built-in Helvetica could not encode.
module UnicodePdfNames
  WORKERS = [
    { first_name: "Aleksandra", last_name: "Wiśniewska", language: "Polish" },
    { first_name: "Jesús", last_name: "Mañibusan", language: "Chamorro" },
    { first_name: "Hương", last_name: "Nguyễn", language: "Vietnamese" },
    { first_name: "Łukasz", last_name: "Żółć", language: "Polish" },
    { first_name: "Keʻala", last_name: "Kāne", language: "Hawaiian" },
    { first_name: "Şükrü", last_name: "Ştefănescu", language: "Turkish/Romanian" },
    { first_name: "Δημήτρης", last_name: "Παπαδόπουλος", language: "Greek" },
    { first_name: "Олена", last_name: "Шевченко", language: "Ukrainian" }
  ].freeze
  # Characters Prawn's built-in fonts reject; a sample of each script.
  TOKENS = %w[Wiśniewska Mañibusan Nguyễn Hương Żółć Kāne Ştefănescu Δημήτρης Шевченко].freeze

  def unicode_pdf_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")
  end
end

RSpec.configure { |config| config.include UnicodePdfNames }
