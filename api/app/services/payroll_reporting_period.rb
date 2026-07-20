# frozen_string_literal: true

# Value object for accountant-facing payroll reports.
#
# Operational payroll reports recognize activity by pay date. A custom range
# therefore includes committed, non-voided payrolls whose pay_date falls inside
# the requested dates; it does not use the dates on which hours were earned.
class PayrollReportingPeriod
  attr_reader :start_date, :end_date, :year

  def self.from_params(params, default_year: Date.current.year)
    start_value = params[:start_date].presence
    end_value = params[:end_date].presence

    if start_value || end_value
      raise ArgumentError, "start_date and end_date are both required" unless start_value && end_value

      return new(
        start_date: parse_iso_date!(start_value, "start_date"),
        end_date: parse_iso_date!(end_value, "end_date")
      )
    end

    year = Integer(params[:year].presence || default_year, exception: false)
    raise ArgumentError, "year must be a valid 4-digit year" unless year&.between?(2000, Date.current.year + 1)

    new(start_date: Date.new(year, 1, 1), end_date: Date.new(year, 12, 31), year: year)
  end

  def self.parse_iso_date!(value, name)
    Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, "#{name} must use YYYY-MM-DD format"
  end
  private_class_method :parse_iso_date!

  def initialize(start_date:, end_date:, year: nil)
    raise ArgumentError, "start_date must be on or before end_date" if start_date > end_date

    @start_date = start_date
    @end_date = end_date
    @year = year || (start_date.year if start_date == Date.new(start_date.year, 1, 1) && end_date == Date.new(start_date.year, 12, 31))
  end

  def range
    start_date..end_date
  end

  def custom?
    year.nil?
  end

  def label
    custom? ? "#{start_date.strftime('%b %-d, %Y')} – #{end_date.strftime('%b %-d, %Y')}" : year.to_s
  end

  def filename_token
    custom? ? "#{start_date}_to_#{end_date}" : year.to_s
  end

  def payload
    {
      basis: "pay_date",
      start_date: start_date,
      end_date: end_date,
      year: year,
      custom: custom?,
      label: label
    }
  end
end
