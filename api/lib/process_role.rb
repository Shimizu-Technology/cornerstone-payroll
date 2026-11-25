# frozen_string_literal: true

module ProcessRole
  ALL = "all"
  PAYROLL_WEB = "payroll_web"
  EMPLOYEE_WEB = "employee_web"
  ROLES = [ ALL, PAYROLL_WEB, EMPLOYEE_WEB ].freeze

  # Every route the employee service may mount. Anything else (admin, client,
  # finance, integrations, /cable) means payroll code leaked onto the service.
  EMPLOYEE_WEB_ROUTE_PATTERN = %r{
    \A(?:
      /(?:up|health/dependencies)(?:\(\.:format\))?
      | /api/v1/(?:employee|kiosk|auth)/.+
      | /api/v1/public/tenant_branding
      | /api/v1/public/employee_terms
      | /api/v1/public/tenant_branding/logo/:slug/:file
    )\z
  }x
  # Primary-pool ceiling for the employee service (M4-10, Neon budget).
  EMPLOYEE_WEB_DB_POOL_MAX = 3

  def self.current
    role = ENV.fetch("APP_PROCESS_ROLE", ALL)
    raise ArgumentError, "APP_PROCESS_ROLE must be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)

    role
  end
end
