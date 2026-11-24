# frozen_string_literal: true

# The invite check fields for sign-up, claim and reactivation, read once from
# the JSON body only, by the same rule the Rack throttle uses
# (EmployeeLinks::Credentials). A request that also names any of them in the
# query string is refused, so the throttle, the controller and the check can
# never act on different values.
#
# Controllers add `before_action :reject_query_credentials!` to those actions.
module EmployeeLinkCheckParams
  extend ActiveSupport::Concern

  INVALID = "Invalid activation request"

  private

  def link_check_params
    body = request.request_parameters
    body = body.is_a?(Hash) ? body.with_indifferent_access : {}
    EmployeeLinks::Credentials::FIELDS.to_h { |field| [ field.to_sym, body[field] ] }
  end

  def link_body_param(name)
    body = request.request_parameters
    body.is_a?(Hash) ? body.with_indifferent_access[name] : nil
  end

  def reject_query_credentials!
    return unless EmployeeLinks::Credentials.conflicting_query?(request.query_parameters)

    response.headers["Cache-Control"] = "no-store"
    render json: { error: INVALID }, status: :bad_request
  end

  def link_check_started!
    @link_check_started_at = EmployeeLinks::ResponseFloor.now
  end

  def wait_for_response_floor
    EmployeeLinks::ResponseFloor.wait_since(@link_check_started_at) if @link_check_started_at
  end
end
