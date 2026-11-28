# frozen_string_literal: true

class EmployeeStatusTransitionService
  class Error < StandardError; end
  class Forbidden < Error; end
  class SelfLifecycleForbidden < Forbidden; end
  class ApprovedRunBlocked < Error
    attr_reader :pay_period, :effective_date

    def initialize(message, pay_period:, effective_date:)
      @pay_period = pay_period
      @effective_date = effective_date
      super(message)
    end
  end

  REACTIVATABLE_STATUSES = %w[inactive terminated].freeze

  def self.open_runs(employee, effective_date: nil)
    runs = PayPeriod.where(company_id: employee.company_id, status: %w[draft calculated approved], run_purpose: "regular")
      .where(id: PayrollItem.where(employee_id: employee.id).select(:pay_period_id))
      .order(:id)
    effective_date ? runs.where("end_date >= ?", effective_date) : runs
  end

  def self.open_run_groups(employee, effective_date:)
    runs = open_runs(employee, effective_date: effective_date)
    {
      remove: runs.where("start_date >= ?", effective_date),
      check: runs.where("start_date < ?", effective_date)
    }
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
    raise Error, "Termination date cannot be in the future" if effective_date > PayrollBusinessClock.today
    last_worked_on = parse_optional_date!(data[:last_worked_on], "last worked date")
    source = data[:source].presence || "operator"

    ApplicationRecord.transaction do
      Company.lock.find(@employee.company_id)
      authorize_terminate!(source)
      remove_runs = lock_remove_runs!(effective_date)
      @employee.lock!
      if source == "client_portal" && EmployeeProfileIdentity.strong_own_record_for_client_managed?(@employee, @actor)
        raise SelfLifecycleForbidden, "You cannot terminate your own employee record."
      end
      raise Error, "This worker is already terminated" if @employee.status == "terminated"
      raise Error, "Termination cannot be before the hire date" if @employee.hire_date && effective_date < @employee.hire_date
      raise Error, "Termination cannot be before the worker's latest status change" if before_latest_status_event?(effective_date)

      block_approved_runs!(remove_runs, effective_date)
      previous_status = @employee.status
      @employee.update!(status: "terminated", termination_date: effective_date)
      event = @employee.employee_status_events.create!(
        company: @employee.company,
        actor: @actor,
        event_type: "terminated",
        previous_status: previous_status,
        resulting_status: "terminated",
        effective_date: effective_date,
        last_worked_on: last_worked_on,
        reason_category: data[:reason_category].presence,
        internal_notes: data[:internal_notes].presence,
        source: source
      )
      EmployeeLinks::Retire.terminated!(@employee, termination_date: effective_date, actor: @actor)
      event
    end
  end

  def deactivate!(attributes)
    data = attributes.to_h.symbolize_keys
    effective_date = parse_date!(data[:effective_date], "inactive date")
    raise Error, "Inactive date cannot be in the future" if effective_date > PayrollBusinessClock.today
    last_worked_on = parse_optional_date!(data[:last_worked_on], "last worked date")

    ApplicationRecord.transaction do
      Company.lock.find(@employee.company_id)
      raise Forbidden, "Payroll staff access required to change a worker's status" unless StaffRolePolicy.allowed?(@actor, :manage_employee_status, company: @employee.company)
      remove_runs = lock_remove_runs!(effective_date)
      @employee.lock!
      raise Error, "Only active workers can be marked inactive" unless @employee.status == "active"
      raise Error, "Inactive date cannot be before the hire date" if @employee.hire_date && effective_date < @employee.hire_date
      raise Error, "Inactive date cannot be before the worker's latest status change" if before_latest_status_event?(effective_date)

      block_approved_runs!(remove_runs, effective_date)
      previous_status = @employee.status
      @employee.update!(status: "inactive")
      event = @employee.employee_status_events.create!(
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
      EmployeeLinks::Retire.deactivated!(@employee, actor: @actor)
      event
    end
  end

  def reactivate!(attributes)
    data = attributes.to_h.symbolize_keys
    effective_date = parse_date!(data[:effective_date], "reactivation date")
    raise Error, "Reactivation date cannot be in the future" if effective_date > PayrollBusinessClock.today
    source = data[:source].presence || "operator"

    ApplicationRecord.transaction do
      Company.lock.find(@employee.company_id)
      authorize_reactivate_entry!(source)
      @employee.lock!
      if source == "client_portal"
        if EmployeeProfileIdentity.strong_own_record_for_client_managed?(@employee, @actor)
          raise SelfLifecycleForbidden, "You cannot rehire your own employee record."
        end
        raise Error, "Only terminated employees can be rehired" unless @employee.status == "terminated"
      else
        # Bringing back a terminated worker is a rehire, which stays with
        # client configuration like termination itself.
        if @employee.status == "terminated" && !StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @employee.company)
          raise Forbidden, "A manager or admin can rehire a terminated worker"
        end
        # Inactive workers (for example, brought over as inactive in a client
        # migration) come back the same way as terminated ones.
        raise Error, "Only inactive or terminated workers can be reactivated" unless REACTIVATABLE_STATUSES.include?(@employee.status)
      end
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
        source: source
      )
    end
  end

  private

  def authorize_terminate!(source)
    if source == "client_portal"
      raise Forbidden, "Client-managed employee lifecycle access required" unless client_portal_lifecycle_allowed?
    elsif !StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @employee.company)
      raise Forbidden, "Client configuration access required"
    end
  end

  def authorize_reactivate_entry!(source)
    if source == "client_portal"
      raise Forbidden, "Client-managed employee lifecycle access required" unless client_portal_lifecycle_allowed?
    elsif !StaffRolePolicy.allowed?(@actor, :manage_employee_status, company: @employee.company)
      raise Forbidden, "Payroll staff access required to change a worker's status"
    end
  end

  def client_portal_lifecycle_allowed?
    return false unless @actor.is_a?(User) && @actor.client? && !@actor.client_viewer?
    return false unless @actor.payroll_access_allowed?(deactivate_closed_practice: false)
    return false unless @actor.can_access_company?(@employee.company_id)
    return false if @employee.company.test_workspace_read_only?

    CompanyFeatures.for(@employee.company).client_managed_employee_lifecycle?
  end

  def lock_remove_runs!(effective_date)
    self.class.open_run_groups(@employee, effective_date: effective_date).fetch(:remove).order(:id).lock.to_a
  end

  def block_approved_runs!(runs, effective_date)
    approved = runs.find(&:approved?)
    return unless approved

    raise ApprovedRunBlocked.new("Unapprove pay run ##{approved.id} first", pay_period: approved, effective_date: effective_date)
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
