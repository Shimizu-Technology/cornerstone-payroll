# frozen_string_literal: true

module ClientOperatingProfiles
  class EffectiveDates
    LIFECYCLE_AMEND_KEYS = %w[client_portal.employee_lifecycle_mode].freeze

    def initialize(company:, latest:, changed_keys: nil)
      @company = company
      @latest = latest
      @changed_keys = changed_keys&.map(&:to_s)
      @today = PayrollBusinessClock.today
    end

    def available
      dates = @company.pay_periods.where(status: "draft").distinct.order(:start_date).pluck(:start_date)
      return [] if dates.empty?

      periods = periods_from(dates.first - 1)
      dates.select { |date| date_error(date, periods).nil? }
    end

    def validate!(date)
      # Called under the company lock. Lock affected runs before checking their
      # status so a concurrent calculation, approval or commit is visible.
      error = date_error(date, periods_from(date - 1).order(:id).lock.to_a)
      raise UpdateService::Invalid, error if error
    end

    def amend?(date)
      return false unless @latest.present? && @latest.version > 1 && @latest.effective_on == date
      return true if date > @today

      return false unless @latest.lifecycle_mode_activated_at.nil? && @latest.lifecycle_mode_activation_failed_at.present?
      return true if @changed_keys.nil?

      @changed_keys.any? && (@changed_keys - LIFECYCLE_AMEND_KEYS).empty?
    end

    private

    def periods_from(date)
      @company.pay_periods.where(end_date: date..)
    end

    def date_error(date, periods)
      affected = periods.select { |period| period.end_date >= date }
      if affected.any? { |period| period.status.in?(%w[calculated approved committed retired_history]) || period.training_baseline? }
        return "This effective date would change a calculated, approved, or committed pay period."
      end

      if affected.any? { |period| period.start_date < date } ||
          affected.none? { |period| period.start_date == date && period.status == "draft" }
        return "The effective date must be the start of a draft pay period."
      end

      return if @latest.nil? || date > @latest.effective_on || amend?(date)
      return if baseline_collision?(date) && periods.none? { |period| (period.start_date..period.end_date).cover?(date - 1) }

      "Effective date must be after the latest profile's start date (#{@latest.effective_on})."
    end

    def baseline_collision?(date)
      @latest.version == 1 && @latest.effective_on == date &&
        @latest.reason == LegacyProfileBuilder::BACKFILL_REASON && @latest.changed_by_id.nil?
    end
  end
end
