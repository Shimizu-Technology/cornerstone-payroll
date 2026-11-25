# frozen_string_literal: true

# The invite check fields for sign-up, claim and reactivation, read once from
# the JSON body only, by the same rule the Rack throttle uses
# (EmployeeLinks::Credentials). A request that also names any of them in the
# query string is refused, so the throttle, the controller and the check can
# never act on different values.
#
# Controllers add `before_action :reject_query_credentials!` to those actions.
#
# The response floor (EmployeeLinks::ResponseFloor) is applied by the
# outermost around_action, after the action, its RLS scope and its database
# connection lease have all finished, and after this thread's connections
# are handed back to the pool: the wait never holds a connection from the
# employee API's small pool.
module EmployeeLinkCheckParams
  extend ActiveSupport::Concern

  INVALID = "Invalid activation request"

  included do
    around_action :apply_response_floor, prepend: true
  end

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

  def require_current_employee_terms
    response.headers["Cache-Control"] = "no-store"
    terms = EmployeeTermsVersion.current
    unless terms
      render json: { error: "Sign-up is unavailable because the Employee App Terms have not been published." },
        status: :service_unavailable
      return
    end
    return terms.version if link_body_param(:terms_version) == terms.version

    render json: { error: "The terms were updated. Please review them again.", code: "terms_updated" },
      status: :conflict
    false
  end

  def link_check_started!
    @link_check_started_at = EmployeeLinks::ResponseFloor.now
  end

  # Asks for the floor on this response; apply_response_floor waits once the
  # action is done.
  def wait_for_response_floor
    @response_floor_requested = true
  end

  def apply_response_floor
    yield
    return unless @response_floor_requested && @link_check_started_at

    ActiveRecord::Base.connection_handler.clear_active_connections!(:all)
    EmployeeLinks::ResponseFloor.wait_since(@link_check_started_at)
  end
end
