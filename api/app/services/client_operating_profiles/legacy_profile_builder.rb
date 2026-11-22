# frozen_string_literal: true

module ClientOperatingProfiles
  # Derives the initial effective-dated operating profile attributes from a
  # company's legacy columns and active time-tracking sources. Used for both
  # idempotent backfill and dual-read fallback when a company has no persisted
  # profile version yet.
  class LegacyProfileBuilder
    BACKFILL_REASON = "Backfilled from legacy company configuration"

    def self.attributes_for(company, effective_on: nil, active_aire_company_ids: nil)
      new(company, effective_on: effective_on, active_aire_company_ids: active_aire_company_ids).attributes
    end

    def self.build(company, effective_on: nil, active_aire_company_ids: nil)
      ClientOperatingProfile.new(
        attributes_for(company, effective_on: effective_on, active_aire_company_ids: active_aire_company_ids)
      )
    end

    def initialize(company, effective_on: nil, active_aire_company_ids: nil)
      @company = company
      @requested_effective_on = effective_on&.to_date
      @active_aire_company_ids = active_aire_company_ids
    end

    def attributes
      offering, hours_source, intake_adapter = classify
      {
        company_id: company.id,
        effective_on: resolved_effective_on,
        ends_on: nil,
        version: 1,
        offering: offering,
        hours_source: hours_source,
        intake_adapter: intake_adapter,
        client_portal_enabled: client_portal_enabled?(offering),
        employee_portal_enabled: false,
        options: build_options(hours_source: hours_source, intake_adapter: intake_adapter),
        reason: BACKFILL_REASON
      }
    end

    private

    attr_reader :company, :requested_effective_on, :active_aire_company_ids

    def classify
      return [ "workforce_suite", "connected_app", nil ] if active_aire_source?

      sources = Array(company.payroll_intake_source_types).map(&:to_s)
      return [ "payroll_portals", "intake_adapter", "mosa_revel" ] if sources.include?("mosa_revel")
      return [ "payroll_service", "intake_adapter", "spike_email" ] if sources.include?("spike_email")

      [ "payroll_service", "manual", nil ]
    end

    def active_aire_source?
      return active_aire_company_ids.include?(company.id) unless active_aire_company_ids.nil?

      company.time_tracking_sources.active.where(source_type: "aire_services").exists?
    end

    def client_portal_enabled?(offering)
      return true if offering == "payroll_portals"
      return true if company.client_payroll_approval_required?

      active_client_portal_users?
    end

    # Deploy-day snapshot of active client-portal posture (editable in M3-5b;
    # nothing reads client_portal_enabled yet). Mirrors User#accessible_company_ids:
    # practice-only logins count only on their open sandbox, while regular client
    # users match organization-scoped unexpired assignments to unarchived companies
    # or fall back to their home company when no such assignment exists.
    def active_client_portal_users?
      now = Time.current
      client_role = User.roles.fetch("client")

      if company.sandbox? && company.active? && company.test_workspace_ready? && !company.test_workspace_read_only?
        practice_login_exists = CompanyAssignment.active_access
          .joins(:user)
          .where(
            company_id: company.id,
            users: {
              role: client_role,
              active: true,
              company_id: company.id,
              practice_company_id: company.id
            }
          )
          .exists?
        return true if practice_login_exists
      end

      if company.test_workspace_archived_at.nil?
        active_assignment_exists = CompanyAssignment.active_access
          .joins(:user)
          .where(
            company_id: company.id,
            users: {
              role: client_role,
              active: true,
              practice_company_id: nil,
              organization_id: company.organization_id
            }
          )
          .exists?
        return true if active_assignment_exists
      end

      User.where(
        company_id: company.id,
        organization_id: company.organization_id,
        role: client_role,
        active: true,
        practice_company_id: nil
      )
        .where(
          "NOT EXISTS (" \
          "SELECT 1 FROM company_assignments " \
          "INNER JOIN companies assigned_companies ON assigned_companies.id = company_assignments.company_id " \
          "WHERE company_assignments.user_id = users.id " \
          "AND (company_assignments.expires_at IS NULL OR company_assignments.expires_at > ?) " \
          "AND assigned_companies.test_workspace_archived_at IS NULL " \
          "AND assigned_companies.organization_id = users.organization_id" \
          ")",
          now
        )
        .exists?
    end

    def resolved_effective_on
      return requested_effective_on if requested_effective_on.present?

      earliest_period = company.pay_periods.minimum(:start_date)
      created_date = company.created_at ? PayrollBusinessClock.date_for(company.created_at) : nil
      [ earliest_period, created_date, PayrollBusinessClock.today, Date.current ].compact.min
    end

    def build_options(hours_source:, intake_adapter:)
      options = OperatingProfileCatalog.default_options

      if hours_source == "intake_adapter" && intake_adapter.present?
        configured = company.payroll_intake_settings.to_h.dig(intake_adapter, "required_sources")
        options["intake"]["required_sources"] = Array(configured).map(&:to_s) unless configured.nil?
      end

      options["tips"]["default"] = intake_adapter == "spike_email" ? "already_paid_out" : "paid_in_check"
      options["overtime"]["mode"] = if hours_source == "connected_app" || intake_adapter == "mosa_revel"
        "source_reports"
      else
        "weekly_split"
      end
      options["workweek"]["alignment"] = intake_adapter == "mosa_revel" ? "warn_if_offset" : "aligned"

      options["year_end"]["kind_of_employer"] = company.kind_of_employer.presence || "N"
      options["year_end"]["contact"]["name"] = company.filing_contact_name.presence
      options["year_end"]["contact"]["phone"] = company.phone.presence
      options["year_end"]["contact"]["email"] = company.email.presence

      options["subdomain_enabled"] = false
      options["time_module_enabled"] = false
      options
    end
  end
end
