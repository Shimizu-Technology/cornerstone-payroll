# frozen_string_literal: true

class EmployeeStatusTransitionService
  class Error < StandardError; end

  def self.terminate!(employee:, actor:, attributes:)
    new(employee:, actor:).terminate!(attributes)
  end

  def self.reactivate!(employee:, actor:, attributes:)
    new(employee:, actor:).reactivate!(attributes)
  end

  def initialize(employee:, actor:)
    @employee = employee
    @actor = actor
  end

  def terminate!(attributes)
    data = attributes.to_h.symbolize_keys
    effective_date = parse_date!(data[:effective_date], "termination date")
    raise Error, "Termination date cannot be in the future" if effective_date > Date.current
    last_worked_on = parse_optional_date!(data[:last_worked_on], "last worked date")

    ApplicationRecord.transaction do
      @employee.lock!
      raise Error, "This worker is already terminated" if @employee.status == "terminated"
      raise Error, "Termination cannot be before the hire date" if @employee.hire_date && effective_date < @employee.hire_date

      previous_status = @employee.status
      @employee.update!(status: "terminated", termination_date: effective_date)
      @employee.employee_status_events.create!(
        company: @employee.company,
        actor: @actor,
        event_type: "terminated",
        previous_status: previous_status,
        resulting_status: "terminated",
        effective_date: effective_date,
        last_worked_on: last_worked_on,
        reason_category: data[:reason_category].presence,
        internal_notes: data[:internal_notes].presence,
        source: data[:source].presence || "operator"
      )
    end
  end

  def reactivate!(attributes)
    data = attributes.to_h.symbolize_keys
    effective_date = parse_date!(data[:effective_date], "reactivation date")
    raise Error, "Reactivation date cannot be in the future" if effective_date > Date.current

    ApplicationRecord.transaction do
      @employee.lock!
      raise Error, "Only terminated workers can be reactivated" unless @employee.status == "terminated"
      if @employee.termination_date && effective_date <= @employee.termination_date
        raise Error, "Reactivation must be after the termination date"
      end

      previous_status = @employee.status
      @employee.update!(status: "active", termination_date: nil)
      @employee.employee_status_events.create!(
        company: @employee.company,
        actor: @actor,
        event_type: "reactivated",
        previous_status: previous_status,
        resulting_status: "active",
        effective_date: effective_date,
        internal_notes: data[:internal_notes].presence,
        source: data[:source].presence || "operator"
      )
    end
  end

  private

  def parse_date!(value, label)
    raise Date::Error if value.blank?

    Date.parse(value.to_s)
  rescue Date::Error
    raise Error, "A valid #{label} is required"
  end

  def parse_optional_date!(value, label)
    return nil if value.blank?

    parse_date!(value, label)
  end
end
