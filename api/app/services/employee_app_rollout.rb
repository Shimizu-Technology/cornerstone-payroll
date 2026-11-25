# frozen_string_literal: true

# Company-scoped read model. Credentials and login records are never serialized.
class EmployeeAppRollout
  EXPIRING_WITHIN = 3.days

  attr_reader :enabled

  def initialize(company, now: Time.current)
    @company = company
    @now = now
    @enabled = EmployeeAccountLink.new(company: company).portal_enabled?
  end

  def employees
    @company.employees.order(:last_name, :first_name, :id)
  end

  def latest_access(employee)
    latest_access_scope.where(employee_id: employee.id).first
  end

  def employee_status(employee, access)
    {
      id: employee.id,
      name: employee.display_name,
      email: employee.email,
      status: status_of(access),
      access_id: access&.id,
      former_access_until: access&.former_access_until,
      invite_expires_at: access&.invite_expires_at,
      invite_delivery: access&.invite_delivery,
      locked_until: access&.activation_locked_until,
      reset_pending: access&.sign_up_reset_pending? || false,
      can_invite: employee.active? && (!access || access.revoked? || access.former?)
    }
  end

  def summary
    # DISTINCT ON returns one row per employee, even across rehires and resends.
    latest = latest_access_scope.select("DISTINCT ON (employee_id) employee_account_links.*")
      .reorder(:employee_id, id: :desc).index_by(&:employee_id)
    contact_context = EmployeeContactValidator.contact_details_context(company: @company)
    candidate_rows = []
    todo = { locked: [], needs_contact_details: [], expiring: [], cleanup: [] }
    counts = { ready_to_invite: 0, invited: 0, active: 0, needs_contact_details: 0, locked: 0, former: 0 }

    employees.each do |employee|
      access = latest[employee.id]
      row = employee_status(employee, access)
      contact = EmployeeContactValidator.contact_details_status(employee, context: contact_context)
      email_ready = EmployeeLinks.email_format?(EmployeeLinks.normalized_email(employee.email)) && contact["email_issue"].nil?
      needs_contact = employee.active? && (contact["needs_contact_details"] || !email_ready)

      if row[:can_invite]
        candidate_rows << row.slice(:id, :name, :email).merge(email_ready: email_ready)
        counts[:ready_to_invite] += 1 if email_ready
      end
      counts[row[:status]] += 1 if counts.key?(row[:status])
      counts[:needs_contact_details] += 1 if needs_contact
      todo[:needs_contact_details] << row.slice(:id, :name) if needs_contact
      todo[:locked] << row.slice(:id, :name, :locked_until) if row[:status] == :locked
      if access&.invite_open?(@now) && access.invite_expires_at <= @now + EXPIRING_WITHIN
        todo[:expiring] << row.slice(:id, :name, :invite_expires_at)
      end
      todo[:cleanup] << row.slice(:id, :name) if employee.status == "inactive" && employee.termination_date.nil?
    end

    { enabled: enabled, counts: counts, candidates: candidate_rows, todo: todo, lock_alert: recent_lock_alert }
  end

  private

  def latest_access_scope
    EmployeeAccountLink.where(company: @company).order(id: :desc)
  end

  def status_of(access)
    return :not_invited unless access
    return :locked if access.invited? && access.activation_locked?(@now)

    access.status.to_sym
  end

  def recent_lock_alert
    AuditLog.where(company: @company, action: "employee_links#activation_lock_alert")
      .where(created_at: (@now - EmployeeAccountLink::LOCK_DURATION)..)
      .order(created_at: :desc, id: :desc).pick(:created_at)
  end
end
