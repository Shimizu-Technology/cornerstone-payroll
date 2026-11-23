# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clerk MFA route coverage" do
  it "requires the shared before-action on each application route that uses Clerk", :aggregate_failures do
    non_clerk_controllers = %w[
      rails/health
      health/dependencies
      api/v1/public/tenant_branding
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
      # Check inherited callback identity. Rails replaces the callback when it
      # adds a conditional skip, even if the filter still appears in the chain.
      base = controller < Api::V1::EmployeePortal::BaseController ? Api::V1::EmployeePortal::BaseController : ApplicationController
      authentication = base == ApplicationController ? :authenticate_user! : :authenticate_employee_user!
      filters = controller._process_action_callbacks.select { |callback| callback.kind == :before }
      expected = base._process_action_callbacks.find { |callback| callback.kind == :before && callback.filter == :enforce_mfa! }
      actual = filters.find { |callback| callback.filter == :enforce_mfa! }
      label = "#{route.verb} #{path} (#{controller_path}##{route.defaults[:action]})"
      expect(actual && actual.equal?(expected)).to be(true), "#{label} lacks the shared MFA filter"
      expect(filters.take_while { |callback| callback != actual }.map(&:filter)).to include(authentication), "#{label} must authenticate before MFA"
    end

    expect(clerk_routes).to include(
      "/api/v1/auth/me(.:format)", "/api/v1/companies(.:format)", "/api/v1/cable_ticket(.:format)",
      "/api/v1/employee/context(.:format)"
    )
  end
end
