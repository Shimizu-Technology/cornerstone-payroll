# frozen_string_literal: true

# Single read boundary for per-client operating profile settings and feature flags.
# In M3-5a (dual-read), existing callers keep reading legacy columns while new code
# and parity checks read through CompanyFeatures.for(company, on:).
class CompanyFeatures
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

  def employee_portal_enabled?
    return false if company.test_workspace?

    profile.employee_portal_enabled == true
  end
  alias_method :employee_portal?, :employee_portal_enabled?

  def employee_portal_feature?(feature)
    key = feature.to_s
    unless OperatingProfileCatalog::EMPLOYEE_PORTAL_FEATURES.include?(key)
      raise ArgumentError, "Unknown employee portal feature: #{feature}"
    end
    return false unless employee_portal_enabled?

    option("employee_portal.features.#{key}") == true
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
    return false if company.test_workspace?

    option("subdomain_enabled") == true
  end

  def time_module_enabled?
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
end
