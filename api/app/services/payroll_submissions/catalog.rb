# frozen_string_literal: true

module PayrollSubmissions
  # Which pay periods a company is offered for submissions.
  #
  # The company's active pay schedule decides. With an anchored weekly or
  # biweekly rule (or a semimonthly rule, which needs no anchor) periods are
  # derived from the schedule. A manual schedule, or a biweekly one with no
  # anchor date yet, offers the regular pay periods Cornerstone has created.
  # Periods already used for a submission stay listed either way. Dates are
  # never hard-coded per client.
  class Catalog
    TIME_ZONE = "Pacific/Guam"
    DERIVED_PAST_PERIODS = 4
    CREATED_PERIOD_LOOKBACK = 120.days
    LIST_LIMIT = 12

    Entry = Struct.new(:start_date, :end_date, :pay_date, :pay_period, :schedule, :source, :record, keyword_init: true) do
      def ref
        record ? record.id.to_s : PayrollSubmissionPeriod.ref_for(start_date, end_date)
      end
    end

    def self.today
      Time.current.in_time_zone(TIME_ZONE).to_date
    end

    def initialize(company:, today: self.class.today)
      @company = company
      @today = today
    end

    attr_reader :today

    def schedule
      return @schedule if defined?(@schedule)

      @schedule = CompanyPaySchedule.for_date(@company.id, @today)
    end

    def derives_from_schedule?
      return false unless schedule

      case schedule.period_rule
      when "weekly", "biweekly" then schedule.period_anchor_date.present?
      when "semimonthly" then true
      else false
      end
    end

    # Newest first: saved periods and offered ones, without duplicates.
    def entries
      records = PayrollSubmissionPeriod.where(company_id: @company.id).order(end_date: :desc, id: :desc).limit(LIST_LIMIT).to_a
      offered = derives_from_schedule? ? derived_entries : created_entries
      by_dates = records.index_by { |record| [ record.start_date, record.end_date ] }
      offered.each { |entry| entry.record ||= by_dates.delete([ entry.start_date, entry.end_date ]) }
      saved = by_dates.values.map { |record| entry_for_record(record) }
      (offered + saved).sort_by { |entry| [ -entry.end_date.jd, -(entry.record&.id || 0) ] }.first(LIST_LIMIT)
    end

    # A period ref is a saved id, or start_end dates the catalog offers now.
    def resolve(ref)
      ref = ref.to_s
      if ref.match?(/\A[1-9]\d*\z/)
        record = PayrollSubmissionPeriod.find_by(id: ref.to_i, company_id: @company.id)
        return record && entry_for_record(record)
      end

      match = ref.match(/\A(\d{4}-\d{2}-\d{2})_(\d{4}-\d{2}-\d{2})\z/)
      return unless match

      start_date = Date.iso8601(match[1])
      end_date = Date.iso8601(match[2])
      record = PayrollSubmissionPeriod.find_by(company_id: @company.id, start_date: start_date, end_date: end_date)
      return entry_for_record(record) if record

      (derives_from_schedule? ? derived_entries : created_entries).find { |entry| entry.start_date == start_date && entry.end_date == end_date }
    rescue Date::Error
      nil
    end

    # Saves an offered period on first use. Safe under concurrent first use.
    def materialize!(entry)
      return entry.record if entry.record

      PayrollSubmissionPeriod.create_or_find_by!(company_id: @company.id, start_date: entry.start_date, end_date: entry.end_date) do |record|
        record.pay_date = entry.pay_date
        record.pay_period = entry.pay_period
        record.company_pay_schedule = entry.schedule
        record.source = entry.source
      end.tap { |record| entry.record = record }
    end

    def open_for_files?(entry)
      @today >= entry.end_date
    end

    def pay_date_for(entry)
      pay_period = live_pay_period(entry)
      pay_period&.pay_date || entry.record&.pay_date || entry.pay_date
    end

    def live_pay_period(entry)
      entry.record&.pay_period || entry.pay_period || matching_pay_period(entry.start_date, entry.end_date)
    end

    private

    def entry_for_record(record)
      Entry.new(start_date: record.start_date, end_date: record.end_date, pay_date: record.pay_date,
        pay_period: record.pay_period, schedule: record.company_pay_schedule, source: record.source, record: record)
    end

    def derived_entries
      @derived_entries ||= derived_ranges.filter_map do |start_date, end_date|
        next if start_date < schedule.effective_on || (schedule.ends_on && end_date > schedule.ends_on)

        pay_period = matching_pay_period(start_date, end_date)
        Entry.new(start_date: start_date, end_date: end_date, schedule: schedule, source: "schedule", pay_period: pay_period,
          pay_date: pay_period&.pay_date || schedule.scheduled_pay_date_for(end_date))
      end
    end

    def derived_ranges
      if schedule.period_rule == "semimonthly"
        cursor = @today.day <= 15 ? @today.beginning_of_month : @today.change(day: 16)
        ranges = []
        (DERIVED_PAST_PERIODS + 1).times do
          ranges << [ cursor, cursor.day == 1 ? cursor.change(day: 15) : cursor.end_of_month ]
          cursor = cursor.day == 1 ? cursor.prev_month.change(day: 16) : cursor.change(day: 1)
        end
        return ranges
      end

      length = schedule.period_rule == "weekly" ? 7 : 14
      anchor = schedule.period_anchor_date
      current = anchor + (((@today - anchor).to_i / length).floor * length)
      (0..DERIVED_PAST_PERIODS).map do |offset|
        start_date = current - (offset * length)
        [ start_date, start_date + (length - 1) ]
      end
    end

    def created_entries
      @created_entries ||= created_pay_periods.map do |pay_period|
        Entry.new(start_date: pay_period.start_date, end_date: pay_period.end_date, pay_date: pay_period.pay_date,
          pay_period: pay_period, schedule: pay_period.company_pay_schedule, source: "pay_period")
      end.uniq { |entry| [ entry.start_date, entry.end_date ] }
    end

    def created_pay_periods
      offerable_pay_periods.where("end_date >= ?", @today - CREATED_PERIOD_LOOKBACK).order(end_date: :desc, id: :desc).limit(LIST_LIMIT)
    end

    def matching_pay_period(start_date, end_date)
      offerable_pay_periods.where(start_date: start_date, end_date: end_date).order(id: :desc).first
    end

    def offerable_pay_periods
      PayPeriod.where(company_id: @company.id, cycle: "regular", run_purpose: "regular", correction_status: nil, test_workspace_role: nil)
    end
  end
end
