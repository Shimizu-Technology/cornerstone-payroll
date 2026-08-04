# frozen_string_literal: true

class EmployeeWorkProfileChangeService
  class Error < StandardError; end

  def self.call!(employee:, actor:, attributes:)
    new(employee:, actor:, attributes:).call!
  end

  def initialize(employee:, actor:, attributes:)
    @employee = employee
    @actor = actor
    @attributes = attributes.to_h.symbolize_keys
  end

  def call!
    effective_on = parse_date!(@attributes.fetch(:effective_on), "effective date")

    ApplicationRecord.transaction do
      @employee.lock!
      current = @employee.employee_work_profiles.find_by(ends_on: nil)
      if current && effective_on <= current.effective_on
        raise Error, "The new work profile must begin after the current profile's effective date"
      end

      current&.update!(ends_on: effective_on - 1.day)

      @employee.employee_work_profiles.create!(
        @attributes.except(:effective_on).merge(
          company: @employee.company,
          effective_on: effective_on,
          confirmed_by: @actor,
          confirmed_at: Time.current,
          confirmation_status: "confirmed"
        )
      )
    end
  rescue KeyError
    raise Error, "Effective date is required"
  end

  private

  def parse_date!(value, label)
    Date.parse(value.to_s)
  rescue Date::Error
    raise Error, "A valid #{label} is required"
  end
end
