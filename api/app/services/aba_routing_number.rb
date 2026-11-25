# frozen_string_literal: true

# The ABA routing-number checksum: 3, 7, 1 weights over nine digits must sum
# to a multiple of ten. Every real routing number passes it.
module AbaRoutingNumber
  WEIGHTS = [ 3, 7, 1 ] * 3

  module_function

  def valid_checksum?(value)
    digits = value.to_s.delete("^0-9")
    return false unless digits.length == 9

    (digits.chars.map(&:to_i).zip(WEIGHTS).sum { |digit, weight| digit * weight } % 10).zero?
  end
end
