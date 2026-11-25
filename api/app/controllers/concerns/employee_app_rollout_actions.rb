# frozen_string_literal: true

module EmployeeAppRolloutActions
  extend ActiveSupport::Concern

  # Email delivery is synchronous. Keep each wave small enough to review
  # recipients and see individual delivery results.
  MAX_WAVE_SIZE = 25
  APP_OFF = "The employee app isn't turned on for this company."
  EMPLOYEE_NOT_FOUND = "Employee not found in this company."

  included do
    before_action :disable_response_caching
    before_action :check_rollout_company
    before_action :require_rollout_access, only: %i[change bulk_invite]

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: EMPLOYEE_NOT_FOUND }, status: :not_found
    end

    rescue_from EmployeeLinks::Error do |error|
      render json: { error: error.message }, status: :unprocessable_content
    end

    rescue_from EmployeeLinks::Forbidden do |error|
      render json: { error: error.message }, status: :forbidden
    end

    rescue_from EmployeeLinks::SignUpAccepted do |error|
      message = if current_user.client? && error.message == EmployeeLinks::Resend::ACCEPTED_STALE
        "This person already created their account, but that sign-up can no longer finish. Ask Cornerstone to reset it."
      else
        error.message
      end
      render json: { error: message, code: "sign_up_accepted" }, status: :conflict
    end
  end

  def show
    summary = rollout.summary(actor: current_user)
    render json: { data: summary.merge(can_manage_invites: can_manage_invites?, max_wave_size: MAX_WAVE_SIZE) }
  end

  def employee
    record = rollout.employees.find(params[:employee_id])
    render json: { data: employee_payload(record) }
  end

  def change
    record = rollout.employees.find(params[:employee_id])
    skip_default_audit_log!
    operation = params[:operation]
    options = { actor: current_user, request: request }
    EmployeeLinks.require_staff!(current_user, current_company) if %w[unlock revoke reset_sign_up].include?(operation)
    access = access_for_change(record) unless operation == "invite"

    result = case operation
    when "invite"
      issue_invite(record, options)
    when "resend"
      EmployeeLinks::Resend.call(link: access, **options, **delivery_options)
    when "unlock"
      EmployeeLinks::Unlock.call(link: access, **options)
      {}
    when "revoke"
      EmployeeLinks::Revoke.call(link: access, reason: reason, **options)
      {}
    when "reset_sign_up"
      EmployeeLinks::ResetSignUp.call(link: access, reason: reason, **options, **delivery_options)
    end
    delivery = result.is_a?(EmployeeLinks::Invite::Result) ? delivery_result(result) : result
    render json: { data: employee_payload(record.reload), **delivery }
  end

  def bulk_invite
    employee_ids = params[:employee_ids]
    unless employee_ids.is_a?(Array) && employee_ids.size.between?(1, MAX_WAVE_SIZE) &&
        employee_ids.all? { |id| positive_id?(id) }
      raise EmployeeLinks::Error, "Select between 1 and #{MAX_WAVE_SIZE} employees."
    end
    delivery = delivery_options.merge(confirm_same_person_email: false)

    skip_default_audit_log!
    # Only this company's records get names or service calls. Preserve the
    # submitted order so results match the operator's wave.
    ids = employee_ids.map(&:to_i).uniq
    records = rollout.employees.where(id: ids).index_by(&:id)
    options = { actor: current_user, request: request, **delivery }
    render json: { data: ids.map { |id| invite_row(id, records[id], options) } }
  end

  private

  def disable_response_caching
    response.headers["Cache-Control"] = "private, no-store"
  end

  def check_rollout_company
    return if current_company && (params[:company_id].nil? || params[:company_id] == current_company.id.to_s)

    render json: { error: "Company not found." }, status: :not_found
  end

  def require_rollout_access
    EmployeeLinks.require_invitation_management!(current_user, current_company)
  end

  def can_manage_invites?
    EmployeeLinks.manage_invitations_allowed?(current_user, current_company)
  end

  def rollout
    @rollout ||= EmployeeAppRollout.new(current_company)
  end

  def employee_payload(record)
    rollout.employee_status(record, rollout.latest_access(record), include_issuer: current_user.staff_member?).merge(
      enabled: rollout.enabled, can_manage_invites: can_manage_invites?,
      staff_actions: EmployeeLinks.staff_management_allowed?(current_user, current_company)
    )
  end

  def positive_id?(value)
    (value.is_a?(Integer) || value.is_a?(String)) && value.to_s.match?(/\A[1-9]\d{0,18}\z/) && value.to_i <= 2**63 - 1
  end

  def access_for_change(record)
    access = rollout.latest_access(record)
    return access if access && positive_id?(params[:access_id]) && access.id == params[:access_id].to_i

    raise EmployeeLinks::Error, "This employee's app access changed. Refresh and try again."
  end

  def reason
    params[:reason] if params[:reason].is_a?(String)
  end

  def delivery_options
    raise EmployeeLinks::Error, APP_OFF unless rollout.enabled

    delivery = params[:delivery]
    raise EmployeeLinks::Error, "Choose email or a printed sign-up code." unless %w[email code].include?(delivery)
    if delivery == "code" && !EmployeeLinks::AppUrl.origin_for(current_company)
      raise EmployeeLinks::Error, "The employee app address isn't set up for this company."
    end

    { delivery: delivery, confirm_same_person_email: params[:confirm_same_person_email] == true }
  end

  def issue_invite(record, options)
    EmployeeLinks::Invite.call(employee: record, **options, **delivery_options)
  end

  def delivery_result(result)
    return { email_status: result.email_status } unless result.code

    { print: {
      name: result.link.employee.display_name,
      code: result.code,
      url: EmployeeLinks::AppUrl.entry_url(current_company, path: result.path),
      expires_at: result.link.invite_expires_at
    } }
  end

  def invite_row(id, record, options)
    return { id: id, error: EMPLOYEE_NOT_FOUND } unless record

    { id: id, **delivery_result(EmployeeLinks::Invite.call(employee: record, **options)) }
  rescue EmployeeLinks::Error => error
    { id: id, error: error.message }
  rescue StandardError => error
    # Keep already-issued codes in the response even if a later row fails.
    Rails.logger.error("[EmployeeAppRollout] Invite failed for employee #{id}: #{error.class}")
    { id: id, error: "Couldn't complete this invite. Check the employee's app status before trying again." }
  end
end
