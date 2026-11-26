# frozen_string_literal: true

# Single read boundary for per-client operating profile settings and feature flags.
# In M3-5a (dual-read), existing callers keep reading legacy columns while new code
# and parity checks read through CompanyFeatures.for(company, on:).
class CompanyFeatures
  # Forthcoming switches the Employee app switch can't turn on: they read as
  # off at read time, as ClientOperatingProfile also refuses to store them on.
  LOCKED_OFF = (OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS - OperatingProfileCatalog::EMPLOYEE_APP_SWITCH_IDS).freeze

  attr_reader :company, :as_of, :profile

  def self.for(company, on: PayrollBusinessClock.today)
    raise ArgumentError, "company is required" unless company.is_a?(Company)

    date = (on || PayrollBusinessClock.today).to_date
    persisted = ClientOperatingProfile.for_date(company.id, date)
    resolved = persisted || ClientOperatingProfiles::LegacyProfileBuilder.build(company, effective_on: date)
    new(company: company, profile: resolved, as_of: date)
  end

  def initialize(company:, profile:, as_of:)
    @company = company
    @profile = profile
    @as_of = as_of
  end

  def persisted?
    profile.persisted?
  end

  def effective_on
    profile.effective_on
  end

  def ends_on
    profile.ends_on
  end

  def version
    profile.version
  end

  def offering
    profile.offering
  end

  def hours_source
    profile.hours_source
  end

  def connected_app?
    hours_source == "connected_app"
  end

  def intake_adapter
    profile.intake_adapter
  end

  def intake_adapter?(key)
    hours_source == "intake_adapter" && intake_adapter == key.to_s
  end

  def intake_required_sources
    return [] unless hours_source == "intake_adapter" && intake_adapter.present?

    configured = option("intake.required_sources")
    return PayrollIntake::SourceCompleteness.default_required_roles(intake_adapter) if configured.nil?

    Array(configured).map(&:to_s)
  end

  def tips_default
    option("tips.default")
  end

  def overtime_mode
    option("overtime.mode")
  end

  def workweek_alignment
    option("workweek.alignment")
  end

  def client_portal?
    profile.client_portal_enabled == true
  end
  alias_method :client_portal_enabled?, :client_portal?

  def review_first?(field_group)
    group = field_group.to_s
    return true if OperatingProfileCatalog::ALWAYS_REVIEWED_GROUPS.include?(group)
    unless OperatingProfileCatalog::CONFIGURABLE_REVIEW_FIRST_GROUPS.include?(group)
      raise ArgumentError, "Unknown review_first field group: #{field_group}"
    end

    option("client_portal.review_first.#{group}") == true
  end

  def client_portal_uploaders
    option("client_portal.uploaders")
  end

  def sensitive_documents_visible?
    option("client_portal.sensitive_documents_visible") == true
  end

  # A practice copy never opens the employee app; a demo company follows its
  # own profile like a live client (demo plan D6), behind the demo gate.
  #
  # M4-9d: a profile flag alone opens nothing. A part is on only while its
  # flag is on AND the Employee app switch's activation for it is unrevoked,
  # so a direct profile write or a future-dated row never skips the
  # readiness checks.
  def employee_portal_enabled?
    return false if company.practice_copy?

    profile.employee_portal_enabled == true && switch_activated?(EmployeeAppSwitch::MASTER)
  end
  alias_method :employee_portal?, :employee_portal_enabled?

  def employee_portal_feature?(feature)
    key = feature.to_s
    unless OperatingProfileCatalog::EMPLOYEE_PORTAL_FEATURES.include?(key)
      raise ArgumentError, "Unknown employee portal feature: #{feature}"
    end
    option_key = "employee_portal.features.#{key}"
    # Bank changes (M4) and the M5 features stay off whatever a row says.
    return false if LOCKED_OFF.include?(option_key)
    return false unless employee_portal_enabled?

    option(option_key) == true && switch_activated?(option_key)
  end

  def employee_stubs_enabled_since
    return unless employee_portal_feature?(:stubs) && persisted?

    enabled_since = effective_on
    ClientOperatingProfile.where(company_id: company.id, effective_on: ...enabled_since)
      .order(effective_on: :desc).each do |previous|
        break unless previous.ends_on == enabled_since - 1.day && previous.employee_portal_enabled &&
          previous.option_value("employee_portal.features.stubs") == true

        enabled_since = previous.effective_on
      end
    enabled_since
  end

  def former_access_years
    option("employee_portal.former_access_years")
  end

  def year_end_kind_of_employer
    option("year_end.kind_of_employer")
  end

  def year_end_contact
    {
      name: option("year_end.contact.name"),
      phone: option("year_end.contact.phone"),
      email: option("year_end.contact.email")
    }
  end

  def subdomain_enabled?
    return false if company.practice_copy?

    option("subdomain_enabled") == true && switch_activated?(EmployeeAppSwitch::SUBDOMAIN)
  end

  # Locked until Milestone 6, whatever a row says.
  def time_module_enabled?
    return false if LOCKED_OFF.include?("time_module_enabled")

    option("time_module_enabled") == true
  end

  def option(key)
    profile.option_value(key)
  end

  def summary
    {
      offering: offering,
      hours_source: hours_source,
      intake_adapter: intake_adapter,
      client_portal_enabled: client_portal_enabled?,
      employee_portal_enabled: employee_portal_enabled?,
      subdomain_enabled: subdomain_enabled?,
      time_module_enabled: time_module_enabled?
    }
  end

  private

  def switch_activated?(part)
    activated_parts.include?(part) && demo_gate_open?
  end

  def activated_parts
    @activated_parts ||= company.persisted? ? EmployeeAppActivation.open_parts_for(company.id) : []
  end

  # A demo company's employee app opens only while the database enforces
  # RLS, or in the shadow state while an in-effect early-access window names
  # it (today, Guam time) and the employee service's guard runs in raise
  # mode as the restricted role: checked on its own process there, and from
  # its signed answer (cached briefly) on staff web and the worker.
  # Requests, jobs and mail all read it here, so each fails closed alike.
  # Employee requests also pass Enforcement.demo_request_allowed?, which
  # always needs the serving process's own guard.
  def demo_gate_open?
    return true unless company.demo?
    return @demo_gate_open if defined?(@demo_gate_open)

    @demo_gate_open = EmployeeAppSwitch::Enforcement.demo_app_open?(company)
  end
end
