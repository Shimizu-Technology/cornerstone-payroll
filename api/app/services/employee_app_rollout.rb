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

  def employee_status(employee, access, include_issuer: false)
    status = {
      id: employee.id,
      name: employee.display_name,
      email: employee.email,
      status: status_of(access),
      access_id: access&.id,
      activated_at: access&.activated_at,
      former_access_until: access&.former_access_until,
      invite_expires_at: access&.invite_expires_at,
      invite_delivery: access&.invite_delivery,
      locked_until: access&.activation_locked_until,
      reset_pending: access&.sign_up_reset_pending? || false,
      can_invite: employee.active? && (!access || access.revoked? || access.former?)
    }
    status[:invited_by_name] = access&.invited_by&.name if include_issuer
    status
  end

  def summary(actor:)
    # DISTINCT ON returns one row per employee, even across rehires and resends.
    latest = latest_access_scope.select("DISTINCT ON (employee_id) employee_account_links.*")
      .reorder(:employee_id, id: :desc).index_by(&:employee_id)
    contact_context = EmployeeContactValidator.contact_details_context(company: @company)
    login_emails = matching_login_emails(contact_context.fetch(:company_email_counts).keys)
    candidate_rows = []
    todo = { locked: [], needs_contact_details: [], expiring: [], reset_pending: [], cleanup: [] }
    counts = { ready_to_invite: 0, invited: 0, active: 0, needs_contact_details: 0, locked: 0, former: 0 }

    employees.each do |employee|
      access = latest[employee.id]
      row = employee_status(employee, access)
      contact = EmployeeContactValidator.contact_details_status(employee, context: contact_context)
      email = EmployeeLinks.normalized_email(employee.email)
      email_ready = EmployeeLinks.email_format?(email) && contact["email_issue"].nil?
      needs_contact = employee.active? && (contact["needs_contact_details"] || !email_ready)

      if row[:can_invite]
        review_email = email_ready && login_emails.include?(email) &&
          !EmployeeContactValidator.validate_for_invite(employee, company: @company, actor: actor).valid?
        candidate_rows << row.slice(:id, :name, :email).merge(email_ready: email_ready && !review_email, email_review_required: review_email)
        counts[:ready_to_invite] += 1 if email_ready && !review_email
      end
      counts[row[:status]] += 1 if counts.key?(row[:status])
      counts[:needs_contact_details] += 1 if needs_contact
      todo[:needs_contact_details] << row.slice(:id, :name) if needs_contact
      todo[:locked] << row.slice(:id, :name, :locked_until) if row[:status] == :locked
      if access&.invited?
        if row[:reset_pending]
          todo[:reset_pending] << row.slice(:id, :name) if actor.staff_member?
        elsif access.invite_expires_at && access.invite_expires_at <= @now + EXPIRING_WITHIN
          todo[:expiring] << row.slice(:id, :name, :invite_expires_at).merge(expired: access.invite_expires_at <= @now)
        end
      end
      if employee.status == "inactive" && employee.termination_date.nil? && !employee.portal_pending_approval?
        todo[:cleanup] << row.slice(:id, :name)
      end
    end

    { enabled: enabled, counts: counts, candidates: candidate_rows, todo: todo, lock_alert: recent_lock_alert }
  end

  private

  def matching_login_emails(employee_emails)
    email = EmployeeContactValidator.normalized_email_node(User.arel_table[:email])
    User.where(email.in(employee_emails)).distinct.pluck(email).to_set
  end

  def latest_access_scope
    EmployeeAccountLink.where(company: @company).includes(:invited_by).order(id: :desc)
  end

  def status_of(access)
    return :not_invited unless access
    # Activation locks are only written while a link is still invited and are
    # cleared on bind/claim, so an active link never carries one.
    return :locked if access.invited? && access.activation_locked?(@now)

    access.status.to_sym
  end

  def recent_lock_alert
    AuditLog.where(company: @company, action: "employee_links#activation_lock_alert")
      .where(created_at: (@now - EmployeeAccountLink::LOCK_DURATION)..)
      .order(created_at: :desc, id: :desc).pick(:created_at)
  end
end
