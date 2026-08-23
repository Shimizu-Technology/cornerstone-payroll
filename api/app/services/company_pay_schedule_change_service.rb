# frozen_string_literal: true

class CompanyPayScheduleChangeService
  class ChangeError < StandardError; end

  def self.call!(company:, actor:, effective_on:, schedule_attributes:, workweek_attributes:)
    new(
      company: company,
      actor: actor,
      effective_on: effective_on,
      schedule_attributes: schedule_attributes,
      workweek_attributes: workweek_attributes
    ).call!
  end

  def initialize(company:, actor:, effective_on:, schedule_attributes:, workweek_attributes:)
    @company = company
    @actor = actor
    @effective_on = effective_on
    @schedule_attributes = schedule_attributes
    @workweek_attributes = workweek_attributes
  end

  def call!
    raise ChangeError, "Effective date is required" if @effective_on.blank?

    Company.transaction do
      @company.lock!
      current_schedule = @company.company_pay_schedules.find_by(ends_on: nil)
      current_workweek = @company.company_workweeks.find_by(ends_on: nil)
      validate_no_queued_configuration!(current_schedule, current_workweek)
      validate_effective_date!(current_schedule, current_workweek)

      close_record!(current_schedule)
      close_record!(current_workweek)

      schedule = @company.company_pay_schedules.create!(
        @schedule_attributes.merge(
          effective_on: @effective_on,
          source: "operator_confirmed",
          confirmation_status: "confirmed",
          confirmed_by: @actor,
          confirmed_at: Time.current
        )
      )
      workweek = @company.company_workweeks.create!(
        @workweek_attributes.merge(
          effective_on: @effective_on,
          source: "operator_confirmed",
          confirmation_status: "confirmed",
          confirmed_by: @actor,
          confirmed_at: Time.current
        )
      )

      @company.update!(pay_frequency: schedule.frequency)
      [ schedule, workweek ]
    end
  end

  private

  def validate_no_queued_configuration!(*records)
    queued_effective_on = records.compact.map(&:effective_on).compact.select { |date| date > configuration_date }.min
    return if queued_effective_on.blank?

    raise ChangeError,
          "A future configuration is already scheduled for #{queued_effective_on}. " \
          "Wait until it becomes effective before scheduling another change."
  end

  def configuration_date
    Time.find_zone!("Pacific/Guam").today
  end

  def validate_effective_date!(*records)
    latest_effective_on = records.compact.map(&:effective_on).compact.max
    return if latest_effective_on.blank? || @effective_on > latest_effective_on

    raise ChangeError, "Effective date must be after the current configuration's effective date (#{latest_effective_on})"
  end

  def close_record!(record)
    record&.update!(ends_on: @effective_on - 1.day)
  end
end
