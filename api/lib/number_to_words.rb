# frozen_string_literal: true

# Converts a monetary amount (Float/BigDecimal/Numeric) to the written-words
# representation used on check faces.
#
# Examples:
#   NumberToWords.convert(1218.91)  # => "One thousand two hundred eighteen and 91/100"
#   NumberToWords.convert(0.00)     # => "Zero and 00/100"
#   NumberToWords.convert(1_000_000)# => "One million and 00/100"
#   NumberToWords.convert(42.05)    # => "Forty-two and 05/100"
#
module NumberToWords
  ONES = %w[
    zero one two three four five six seven eight nine
    ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen
  ].freeze

  TENS = %w[
    "" "" twenty thirty forty fifty sixty seventy eighty ninety
  ].freeze

  SCALE = [
    [ 1_000_000_000, "billion" ],
    [ 1_000_000,     "million" ],
    [ 1_000,         "thousand" ],
    [ 100,           "hundred" ],
  ].freeze

  # Public entry point.
  # @param amount [Numeric] – e.g., 1218.91
  # @return [String] – e.g., "One thousand two hundred eighteen and 91/100"
  def self.convert(amount)
    amount = BigDecimal(amount.to_s)
    dollars = amount.to_i.abs
    cents   = ((amount - dollars) * 100).round.to_i.abs

    word_part  = dollars.zero? ? "zero" : integer_to_words(dollars)
    cents_part = cents.to_s.rjust(2, "0")

    "#{word_part.capitalize} and #{cents_part}/100"
  end

  # @param n [Integer] must be >= 0
  # @return [String]
  def self.integer_to_words(n)
    return ONES[n] if n < 20
    return "#{TENS[n / 10]}#{'-' + ONES[n % 10] if (n % 10).positive?}" if n < 100

    parts = []

    SCALE.each do |divisor, name|
      next if n < divisor

      # Special case for hundreds (no recursive "hundred" call needed at the 100 level)
      if divisor == 100
        parts << "#{ONES[n / 100]} hundred"
        n %= 100
      else
        quotient = n / divisor
        parts << "#{integer_to_words(quotient)} #{name}"
        n %= divisor
      end
    end

    parts << integer_to_words(n) if n.positive?
    parts.join(" ")
  end

  private_class_method :integer_to_words
end
