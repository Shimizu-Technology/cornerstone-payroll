# frozen_string_literal: true

module ProcessRole
  ALL = "all"
  PAYROLL_WEB = "payroll_web"
  EMPLOYEE_WEB = "employee_web"
  ROLES = [ ALL, PAYROLL_WEB, EMPLOYEE_WEB ].freeze

  def self.current
    role = ENV.fetch("APP_PROCESS_ROLE", ALL)
    raise ArgumentError, "APP_PROCESS_ROLE must be one of: #{ROLES.join(', ')}" unless ROLES.include?(role)

    role
  end
end
