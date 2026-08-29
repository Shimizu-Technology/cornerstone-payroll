# frozen_string_literal: true

class PayPeriodConfirmedWorkweekAdoptionService
  class AdoptionError < StandardError; end

  def self.call!(pay_period:)
    new(pay_period: pay_period).call!
  end

  def self.candidate_for(pay_period)
    return unless pay_period.draft?
    return if pay_period.payroll_items.exists?
    return if pay_period.time_tracking_imports.exists?
    return if pay_period.payroll_intake_sessions.exists?

    assigned_workweek = pay_period.resolved_company_workweek
    return if assigned_workweek.blank? || assigned_workweek.confirmed?

    pay_period.company.company_workweeks
              .where(
                confirmation_status: "confirmed",
                starts_on_weekday: assigned_workweek.starts_on_weekday,
                starts_at_minutes: assigned_workweek.starts_at_minutes,
                timezone: assigned_workweek.timezone
              )
              .order(confirmed_at: :desc, effective_on: :desc, id: :desc)
              .first
  end

  def initialize(pay_period:)
    @pay_period = pay_period
  end

  def call!
    pay_period.with_lock do
      validate_empty_draft!

      candidate = self.class.candidate_for(pay_period)
      unless candidate
        raise AdoptionError,
              "No confirmed workweek with the same weekday, start time, and timezone is available for this draft."
      end

      pay_period.update!(company_workweek: candidate)
    end

    pay_period
  end

  private

  attr_reader :pay_period

  def validate_empty_draft!
    raise AdoptionError, "Only a draft pay period can adopt a confirmed workweek." unless pay_period.draft?

    if pay_period.payroll_items.exists? || pay_period.time_tracking_imports.exists? || pay_period.payroll_intake_sessions.exists?
      raise AdoptionError,
            "This draft already contains payroll or import evidence. Reconfirm the workweek before entering payroll data, or create a clean draft."
    end
  end
end
