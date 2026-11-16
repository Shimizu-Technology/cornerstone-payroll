# frozen_string_literal: true

class EmployeeStatusTransitionService
  class Error < StandardError; end

  REACTIVATABLE_STATUSES = %w[inactive terminated].freeze

  def self.open_runs(employee)
    PayPeriod.where(company_id: employee.company_id, status: %w[draft calculated approved])
      .where(id: PayrollItem.where(employee_id: employee.id).select(:pay_period_id))
      .order(:id)
  end

  def self.terminate!(employee:, actor:, attributes:)
    new(employee:, actor:).terminate!(attributes)
  end

  def self.reactivate!(employee:, actor:, attributes:)
    new(employee:, actor:).reactivate!(attributes)
  end

  def self.deactivate!(employee:, actor:, attributes:)
    new(employee:, actor:).deactivate!(attributes)
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
      raise Error, "Client configuration access required" unless StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @employee.company)
      raise Error, "This worker is already terminated" if @employee.status == "terminated"
      raise Error, "Termination cannot be before the hire date" if @employee.hire_date && effective_date < @employee.hire_date
      raise Error, "Termination cannot be before the worker's latest status change" if before_latest_status_event?(effective_date)

      block_approved_runs!(effective_date)
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

  def deactivate!(attributes)
    data = attributes.to_h.symbolize_keys
    effective_date = parse_date!(data[:effective_date], "inactive date")
    raise Error, "Inactive date cannot be in the future" if effective_date > Date.current
    last_worked_on = parse_optional_date!(data[:last_worked_on], "last worked date")

    ApplicationRecord.transaction do
      @employee.lock!
      raise Error, "Client configuration access required" unless StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @employee.company)
      raise Error, "Only active workers can be marked inactive" unless @employee.status == "active"
      raise Error, "Inactive date cannot be before the hire date" if @employee.hire_date && effective_date < @employee.hire_date
      raise Error, "Inactive date cannot be before the worker's latest status change" if before_latest_status_event?(effective_date)

      block_approved_runs!(effective_date)
      previous_status = @employee.status
      @employee.update!(status: "inactive")
      @employee.employee_status_events.create!(
        company: @employee.company,
        actor: @actor,
        event_type: "deactivated",
        previous_status: previous_status,
        resulting_status: "inactive",
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
      raise Error, "Client configuration access required" unless StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @employee.company)
      # Inactive workers (for example, brought over as inactive in a client
      # migration) come back the same way as terminated ones.
      raise Error, "Only inactive or terminated workers can be reactivated" unless REACTIVATABLE_STATUSES.include?(@employee.status)
      if @employee.termination_date && effective_date <= @employee.termination_date
        raise Error, "Reactivation must be after the termination date"
      end
      raise Error, "Reactivation must be after the worker's latest status change" if @employee.employee_status_events.where("effective_date >= ?", effective_date).exists?

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

  def block_approved_runs!(effective_date)
    runs = self.class.open_runs(@employee).where("start_date <= ? AND end_date >= ?", effective_date, effective_date).lock.to_a
    approved = runs.find(&:approved?)
    raise Error, "Unapprove pay run ##{approved.id} first" if approved
  end

  # Status events form one timeline; a backdated change would rewrite which
  # status applied on earlier payroll dates.
  def before_latest_status_event?(effective_date)
    @employee.employee_status_events.where("effective_date > ?", effective_date).exists?
  end

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
