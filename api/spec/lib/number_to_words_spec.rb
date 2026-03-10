# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/number_to_words"

RSpec.describe NumberToWords do
  describe ".convert" do
    {
      0.00        => "Zero and 00/100",
      1.00        => "One and 00/100",
      10.00       => "Ten and 00/100",
      11.00       => "Eleven and 00/100",
      20.00       => "Twenty and 00/100",
      42.05       => "Forty-two and 05/100",
      99.99       => "Ninety-nine and 99/100",
      100.00      => "One hundred and 00/100",
      101.01      => "One hundred one and 01/100",
      999.99      => "Nine hundred ninety-nine and 99/100",
      1_000.00    => "One thousand and 00/100",
      1_218.91    => "One thousand two hundred eighteen and 91/100",
      10_000.00   => "Ten thousand and 00/100",
      52_000.00   => "Fifty-two thousand and 00/100",
      100_000.00  => "One hundred thousand and 00/100",
      1_000_000   => "One million and 00/100",
    }.each do |amount, expected|
      it "converts #{amount} correctly" do
        expect(described_class.convert(amount)).to eq(expected)
      end
    end

    it "handles BigDecimal input" do
      expect(described_class.convert(BigDecimal("1218.91"))).to eq("One thousand two hundred eighteen and 91/100")
    end

    it "handles string input" do
      expect(described_class.convert("42.05")).to eq("Forty-two and 05/100")
    end

    it "pads single-digit cents with leading zero" do
      expect(described_class.convert(5.09)).to eq("Five and 09/100")
    end
  end
end
