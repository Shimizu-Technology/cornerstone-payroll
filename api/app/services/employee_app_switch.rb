# frozen_string_literal: true

# M4-9d: the per-company employee app switch. An org admin lifts the M4 lock
# for one company at a time, one part at a time, behind readiness checks
# (docs/MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md §4 M4-9). Turning
# anything off always works. Values live in the company's operating profile.
module EmployeeAppSwitch
  class Error < StandardError; end
  class Forbidden < Error; end
  class Invalid < Error; end
  # Turning on needs a fresh step-up (MfaPolicy.recently_step_up_verified?):
  # a second factor with REQUIRE_MFA on, a first factor while it's off.
  class StepUpRequired < Error
    def initialize(message = "Confirm it's you again to turn this on.")
      super
    end
  end

  # Raised when a turn-on fails a readiness check; lists each failing check.
  class NotReady < Error
    attr_reader :failures

    def initialize(failures)
      @failures = failures
      super("Not ready to turn on: #{failures.map(&:name).join('; ')}")
    end
  end

  MASTER = "employee_portal_enabled"
  SUBDOMAIN = "subdomain_enabled"
  FEATURES = %w[stubs tax_forms profile_requests delivery_consent].map { |key| "employee_portal.features.#{key}" }.freeze
  # The same list the catalog marks as managed here, in screen order.
  KEYS = OperatingProfileCatalog::EMPLOYEE_APP_SWITCH_IDS

  SWITCHES = {
    MASTER => {
      label: "Employee app",
      description: "Employees can sign up and sign in to this company's employee app.",
      counsel: %i[terms]
    },
    SUBDOMAIN => {
      label: "Company web address",
      description: "The company's own web address opens its employee app.",
      counsel: []
    },
    "employee_portal.features.stubs" => {
      label: "Pay stubs",
      description: "Employees can view and download their pay stubs.",
      counsel: []
    },
    "employee_portal.features.tax_forms" => {
      label: "Tax forms",
      description: "Employees can view and download their posted W-2GU copies.",
      counsel: []
    },
    "employee_portal.features.profile_requests" => {
      label: "Contact and address updates",
      description: "Employees can ask to update their contact details and home address.",
      counsel: []
    },
    "employee_portal.features.delivery_consent" => {
      label: "Electronic delivery consent",
      description: "Employees can give or withdraw consent to get pay statements and W-2GU electronically.",
      counsel: %i[consent]
    }
  }.freeze

  # Shown on the screen; never switchable here (D3).
  STAYS_OFF = {
    "employee_portal.features.bank_requests" => {
      label: "Bank account changes",
      description: "Stays off. Bank changes need text-message codes, which aren't built yet."
    }
  }.freeze

  AUDIT_ACTION = "employee_app_switch#changed"
  REASON_MAX = 500

  module_function

  def label(key)
    SWITCHES.dig(key, :label) || key
  end

  # Org admins (and platform admins) with payroll access to the company.
  def allowed?(user, company)
    user.present? && company.present? && StaffRolePolicy.allowed?(user, :manage_employee_app_switch) &&
      user.payroll_access_allowed? && user.can_access_company?(company.id)
  end

  # A live client or a demo company can use the employee app; other test
  # workspaces and inactive companies can't.
  def eligible_company?(company)
    company.active? && company.organization&.active? && company.operating?
  end

  # The stored values, from the profile version in effect today. Unlike
  # CompanyFeatures, this doesn't force a test workspace's values off, so a
  # demo's own switches show as set.
  def stored_values(company, today: PayrollBusinessClock.today)
    profile = ClientOperatingProfile.for_date(company.id, today)
    KEYS.index_with do |key|
      next false unless profile

      (key == MASTER ? profile.employee_portal_enabled : profile.option_value(key)) == true
    end
  end

  # What the switch shows as on: the stored value today AND an unrevoked
  # activation (a flag written around the switch isn't on).
  def switched_on_values(company, today: PayrollBusinessClock.today)
    activated = EmployeeAppActivation.open_parts_for(company.id)
    stored_values(company, today: today).to_h { |key, value| [ key, value && activated.include?(key) ] }
  end

  # Parts with anything left to turn off: on today, on in a later scheduled
  # version, or still holding an unrevoked activation.
  def on_anywhere(company, today: PayrollBusinessClock.today)
    profiles = company.client_operating_profiles.where("ends_on IS NULL OR ends_on >= ?", today).to_a
    activated = EmployeeAppActivation.open_parts_for(company.id)
    KEYS.select do |key|
      activated.include?(key) || profiles.any? { |profile| profile_value(profile, key) }
    end
  end

  def profile_value(profile, key)
    (key == MASTER ? profile.employee_portal_enabled : profile.option_value(key)) == true
  end

  # Whether each part is actually open today, as the employee API decides.
  def effective_values(company, today: PayrollBusinessClock.today, retire_windows: true)
    features = CompanyFeatures.for(company, on: today, retire_windows: retire_windows)
    KEYS.index_with do |key|
      case key
      when MASTER then features.employee_portal_enabled?
      when SUBDOMAIN then features.subdomain_enabled?
      else features.employee_portal_feature?(key.delete_prefix("employee_portal.features."))
      end
    end
  end

  def reason!(value)
    reason = value.is_a?(String) ? value.strip : ""
    raise Invalid, "Enter a reason for the change." if reason.empty?
    raise Invalid, "Keep the reason under #{REASON_MAX} characters." if reason.length > REASON_MAX

    reason
  end
end
