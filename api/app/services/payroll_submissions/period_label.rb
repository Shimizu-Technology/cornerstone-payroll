# frozen_string_literal: true

module PayrollSubmissions
  # "Nov 1–14, 2026", "Oct 19 – Nov 1, 2026", "Dec 28, 2026 – Jan 10, 2027".
  module PeriodLabel
    def self.call(start_date, end_date)
      if start_date.year != end_date.year
        "#{start_date.strftime('%b %-d, %Y')} – #{end_date.strftime('%b %-d, %Y')}"
      elsif start_date.month != end_date.month
        "#{start_date.strftime('%b %-d')} – #{end_date.strftime('%b %-d, %Y')}"
      else
        "#{start_date.strftime('%b %-d')}–#{end_date.strftime('%-d, %Y')}"
      end
    end
  end
end
