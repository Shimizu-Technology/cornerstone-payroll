# frozen_string_literal: true

module ClientProfitability
  # A report period made of whole months, "YYYY-MM" through "YYYY-MM".
  class Period
    MAX_MONTHS = 24
    MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/

    attr_reader :start_date, :end_date

    def self.parse(from, through)
      start_date = month(from, "from")
      end_date = month(through.presence || from, "through").end_of_month
      raise ArgumentError, "The end month must be on or after the start month" if end_date < start_date

      months = ((end_date.year * 12) + end_date.month) - ((start_date.year * 12) + start_date.month) + 1
      raise ArgumentError, "Choose at most #{MAX_MONTHS} months" if months > MAX_MONTHS

      new(start_date, end_date)
    end

    def self.month(value, name)
      match = MONTH.match(value.to_s)
      raise ArgumentError, "#{name} must be a month like 2026-10" unless match

      Date.new(match[1].to_i, match[2].to_i, 1)
    end

    def initialize(start_date, end_date)
      @start_date = start_date
      @end_date = end_date
    end

    def range
      start_date..end_date
    end

    def months
      list = []
      month = start_date
      while month <= end_date
        list << month
        month = month.next_month
      end
      list
    end

    def label
      first = start_date.strftime("%B %Y")
      last = end_date.strftime("%B %Y")
      first == last ? first : "#{first} – #{last}"
    end

    def as_json(*)
      { from: start_date.strftime("%Y-%m"), through: end_date.strftime("%Y-%m"), start_date: start_date.iso8601,
        end_date: end_date.iso8601, label: label }
    end
  end
end
