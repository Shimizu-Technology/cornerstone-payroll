# frozen_string_literal: true

# Formats exact check numbers for transmittal-style documents without implying
# that missing numbers in a range were issued.
class CheckNumberRangeFormatter
  def self.format(numbers)
    new(numbers).format
  end

  def initialize(numbers)
    @numbers = Array(numbers).map(&:to_s).map(&:strip).reject(&:blank?)
  end

  def format
    return "" if @numbers.empty?

    (numeric_ranges + non_numeric_numbers).join(", ")
  end

  private

  def numeric_ranges
    numeric_numbers
      .map(&:to_i)
      .uniq
      .sort
      .chunk_while { |previous, current| current == previous + 1 }
      .map { |range| range.size == 1 ? range.first.to_s : "#{range.first}-#{range.last}" }
  end

  def numeric_numbers
    @numbers.select { |number| number.match?(/\A\d+\z/) }
  end

  def non_numeric_numbers
    @numbers.reject { |number| number.match?(/\A\d+\z/) }.uniq.sort
  end
end
