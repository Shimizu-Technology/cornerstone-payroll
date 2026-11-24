# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clerk MFA route coverage" do
  it "requires the shared before-action on each application route that uses Clerk", :aggregate_failures do
    non_clerk_controllers = %w[
      rails/health
      health/dependencies
      api/v1/public/tenant_branding
      api/v1/employee_portal/activations
      api/v1/finance/access
      api/v1/integrations/aire/events
      api/v1/integrations/aire/cutoff_changes
      api/v1/integrations/aire/worker_statements
    ]
    clerk_routes = []

    Rails.application.routes.routes.each do |route|
      controller_path = route.defaults[:controller]
      path = route.path.spec.to_s
      # Rails mounts framework storage and mail routes with their own authentication.
      next if controller_path&.match?(%r{\A(?:active_storage|action_mailbox|rails/conductor)/})
      next if path == "/cable" # Ticket redemption is exercised in the ActionCable connection specs.

      controller = "#{controller_path.camelize}Controller".constantize
      if non_clerk_controllers.include?(controller_path) && !(controller < MfaEnforceable)
        expect(controller < ClerkAuthenticatable).to be_falsey, "#{path} now uses Clerk"
        next
      end

      clerk_routes << path
      label = "#{route.verb} #{path} (#{controller_path}##{route.defaults[:action]})"
      errors = mfa_coverage_errors(controller)
      expect(errors).to be_empty, "#{label}: #{errors.join(', ')}"
    end

    expect(clerk_routes).to include(
      "/api/v1/auth/me(.:format)", "/api/v1/companies(.:format)", "/api/v1/cable_ticket(.:format)",
      "/api/v1/employee/context(.:format)", "/api/v1/employee/links", "/api/v1/employee/links/claim",
      "/api/v1/employee/links/reactivate"
    )
  end

  [
    [ "a conditional Clerk authentication skip", :authenticate_user!, -> { skip_before_action :authenticate_user!, only: :show } ],
    [ "a conditional employee authentication skip", :authenticate_employee_user!, -> { skip_before_action :authenticate_employee_user!, except: :show } ],
    [ "a conditional MFA skip", :enforce_mfa!, -> { skip_before_action :enforce_mfa!, only: :show } ],
    [ "a conditional MFA callback", :enforce_mfa!, -> { before_action :enforce_mfa!, if: :show } ],
    [ "an MFA enforcement override", :enforce_mfa!, -> { define_method(:enforce_mfa!) { nil } } ],
    [ "an MFA response override", :render_mfa_required, -> { define_method(:render_mfa_required) { nil } } ],
    [ "an authentication bypass override", :auth_disabled?, -> { define_method(:auth_disabled?) { true } } ]
  ].each do |scenario, method, change|
    it "detects #{scenario}" do
      base = method == :authenticate_employee_user! ? Api::V1::EmployeePortal::BaseController : ApplicationController
      controller = Class.new(base)
      controller.class_exec(&change)

      expect(mfa_coverage_errors(controller)).to include(a_string_including(method.to_s))
    end
  end

  def mfa_coverage_errors(controller)
    employee_portal = controller <= Api::V1::EmployeePortal::BaseController
    base = employee_portal ? Api::V1::EmployeePortal::BaseController : ApplicationController
    authentication = employee_portal ? :authenticate_employee_user! : :authenticate_user!
    methods = [ authentication, :enforce_mfa! ]
    filters = controller._process_action_callbacks.select { |callback| callback.kind == :before }
    base_filters = base._process_action_callbacks.select { |callback| callback.kind == :before }
    errors = methods.filter_map do |method|
      actual = filters.find { |callback| callback.filter == method }
      expected = base_filters.find { |callback| callback.filter == method }
      # Rails clones a callback when a subclass conditionally skips it. The
      # sole permitted condition is the existing development Clerk bypass.
      allowed_unless = employee_portal ? [] : [ :auth_disabled? ]
      unless actual && actual.equal?(expected) &&
          actual.instance_variable_get(:@if).empty? && actual.instance_variable_get(:@unless) == allowed_unless
        "#{method} must use the shared callback without additional conditions"
      end
    end

    unless filters.select { |callback| methods.include?(callback.filter) }.map(&:filter) == methods
      errors << "#{authentication} must run before enforce_mfa!"
    end

    owners = {
      authentication => employee_portal ? base : ClerkAuthenticatable,
      enforce_mfa!: MfaEnforceable,
      render_mfa_required: controller <= Api::V1::AuthController ? Api::V1::AuthController : MfaEnforceable
    }
    owners[:auth_disabled?] = ApplicationController unless employee_portal
    owners.each do |method, owner|
      errors << "#{method} must be owned by #{owner}" unless controller.instance_method(method).owner == owner
    end
    errors
  end
end
