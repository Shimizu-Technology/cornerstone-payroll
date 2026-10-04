# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

# This fixture admits an existing provider identity to local staging only.
# Load it through either application's Rails runner; it never calls Clerk.
module StagingAcceptance
  class ManualFixture
    class GuardError < StandardError; end

    FIXTURE = "actual-operator-manual-acceptance-v1"
    RESERVED_IDS = 920_000...930_000
    OPERATOR_ID = 920_001
    MAINTAINER_ID = 920_002
    EMPLOYEE_ID = 920_101
    ENTRY_ID = 920_301
    EMPLOYEE_UUID = "20000000-0000-4000-8000-000000920101"
    PURPOSE = "Synthetic acceptance fixture, no real employee/business evidence"
    DATABASES = { "payroll" => "cornerstone_payroll_staging_v2", "aire" => "aire_services_staging_v2" }.freeze
    PAYROLL_TABLES = %w[organizations companies users company_assignments employees departments company_pay_schedules company_workweeks time_tracking_sources time_tracking_employee_mappings pay_periods payroll_items employee_wage_rates employee_document_requirements employee_document_requirement_events time_tracking_manual_allocations time_tracking_entry_allocations aire_verified_history_rollout_receipts aire_payroll_calendar_periods aire_payroll_calendar_publications].freeze
    AIRE_TABLES = %w[users time_categories user_time_categories time_entries settings payroll_calendar_periods payroll_calendar_period_revisions payroll_batches payroll_batch_entries payroll_batch_exclusions payroll_settlement_cases payroll_settlement_case_events payroll_account_links payroll_account_link_sessions payroll_integration_grants payroll_manual_allocations payroll_manual_allocation_events payroll_payment_attestations payroll_payment_attestation_events payroll_time_entry_revisions].freeze

    def initialize(environment: ENV)
      @environment = environment
    end

    def run!
      guard_environment!
      ApplicationRecord.transaction do
        connection.execute("SELECT pg_advisory_xact_lock(920_301_004)")
        guard_admission!
        original = protected_rows
        identity = verify_installation!
        if mode == "apply"
          app == "payroll" ? create_payroll!(identity) : create_aire!
          assert_protected_rows!(original)
        end
        {
          fixture: FIXTURE, app: app, mode: mode,
          existing_rows_unchanged: true,
          protected_table_digests: original.transform_values { |row| row.fetch(:digest) },
          principal_admission: "existing_provider_identity_local_record_only",
          operator_role: app == "payroll" ? "accountant" : "active_personal_admin",
          business_approvals_created: 0, historical_approvals_created: 0,
          own_links_created: 0, delegations_created: 0, payments_created: 0,
          calendars_created: 0, committed_periods_created: 0,
          fixture_setup_actor: app == "payroll" ? "inactive_non_login_fixture_maintainer" : nil,
          setup_purpose: PURPOSE,
          pending_hours: 4, source_installation_verified: true,
          readiness: app == "payroll" ? "synthetic_setup_only" : "manual_time_approval_pending"
        }.compact
      end
    end

    def guard_environment!
      unless Rails.env.production? && environment["DEPLOYMENT_ENV"] == "staging" &&
             environment["STAGING_SEED_ALLOWED"] == "true" && environment["STAGING_FIXTURE_NAMESPACE"] == "staging-v2" &&
             environment["STAGING_ACCEPTANCE_FIXTURE"] == FIXTURE && %w[dry_run apply].include?(mode)
        raise GuardError, "Explicit staging fixture guards and dry_run/apply mode are required"
      end
      unless DATABASES.value?(connection.select_value("SELECT current_database()")) &&
             database_name == connection.select_value("SELECT current_database()")
        raise GuardError, "The configured and actual database must match an exact local staging database"
      end
      unless ActiveRecord::Base.connection_db_config.configuration_hash.fetch(:host, nil) == "#{app}-db" &&
             connection.select_value("SELECT current_user") == "#{app}_staging_v2"
        raise GuardError, "Only the local staging Compose database host and role are allowed"
      end
      if environment["CERTIFICATION_CLOCK_FILE"].present? ||
         (Time.current.to_f - Process.clock_gettime(Process::CLOCK_REALTIME)).abs > 5
        raise GuardError, "This hosted fixture requires the real clock"
      end
      raise GuardError, "The source installation UUID is required" unless installation_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
      unless principal.fetch(:clerk_id).match?(/\Auser_[a-zA-Z0-9]+\z/) &&
             principal.fetch(:email).match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) && principal.fetch(:name).present?
        raise GuardError, "Verified existing provider principal inputs are required"
      end
    end

    private

      attr_reader :environment

      def connection
        ActiveRecord::Base.connection
      end

      def database_name
        ActiveRecord::Base.connection_db_config.database.to_s
      end

      def app
        DATABASES.key(database_name)
      end

      def mode
        environment.fetch("STAGING_ACCEPTANCE_MODE", "dry_run")
      end

      def installation_id
        environment.fetch("STAGING_SOURCE_INSTANCE_ID", "").downcase
      end

      def principal
        @principal ||= {
          clerk_id: environment.fetch("STAGING_ACTUAL_CLERK_ID", "").strip,
          email: environment.fetch("STAGING_ACTUAL_EMAIL", "").strip.downcase,
          name: environment.fetch("STAGING_ACTUAL_NAME", "").strip
        }
      end

      def fixture_tables
        app == "payroll" ? PAYROLL_TABLES : AIRE_TABLES
      end

      def guard_admission!
        unless fixture_tables.all? { |table| connection.data_source_exists?(table) }
          raise GuardError, "Required fixture schema is missing"
        end
        fixture_tables.each do |table|
          sql = "SELECT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)} WHERE id >= 920000 AND id < 930000)"
          raise GuardError, "Reserved fixture namespace is occupied; do not update or reseed it" if connection.select_value(sql)
        end
        if User.where(clerk_id: principal.fetch(:clerk_id)).exists? || User.where("LOWER(email) = ?", principal.fetch(:email)).exists?
          raise GuardError, "The actual principal already has a local account; review it instead of replacing it"
        end
        if app == "aire" && PayrollAccountLink.where(external_system: "cornerstone_payroll", external_actor_id: OPERATOR_ID.to_s).exists?
          raise GuardError, "The new operator actor reference is already linked"
        end
        if app == "payroll"
          raise GuardError, "The original synthetic staging organization is unavailable" unless Organization.find_by(id: 910_001, slug: "aire-payroll-staging-v2", status: "active")
        elsif PayrollCalendarPeriod.where("start_date <= ? AND end_date >= ?", work_date, work_date).exists?
          raise GuardError, "The synthetic work date is covered by an existing calendar; do not repair its policy"
        end
        if app == "aire" && TimeEntry.where(work_date: period_start..period_end).exists?
          raise GuardError, "The manual fixture range already contains source hours"
        end
      end

      def verify_installation!
        if app == "aire"
          unless Setting.find_by(key: "payroll_source_instance_id")&.value.to_s.downcase == installation_id
            raise GuardError, "The existing AIRE installation does not match the explicit pin"
          end
          return nil
        end

        template = TimeTrackingSource.find_by(id: 910_001, source_type: "aire_services", active: true)
        unless template&.shared_secret_configured? && template.company_id == 910_001
          raise GuardError, "The original active staging transport is unavailable"
        end
        candidate = TimeTrackingSource.new(name: FIXTURE, source_type: "aire_services", base_url: template.base_url,
                                          shared_secret: template.shared_secret, expected_source_instance_id: installation_id)
        payload = TimeTracking::Client.new(candidate).time_summary(start_date: period_start.iso8601, end_date: period_end.iso8601)
        identity = TimeTracking::ConnectionIdentity.validate!(source: candidate, payload: payload)
        raise GuardError, "The existing AIRE installation must return its verified protocol identity" if identity.legacy
        identity
      end

      def create_payroll!(identity)
        company = Company.create!(id: OPERATOR_ID, organization_id: 910_001,
          name: "SYNTHETIC Actual Operator Manual Acceptance", payroll_environment: "live", active: true,
          pay_frequency: "semimonthly", ein: "00-0000098", city: "Hagåtña", state: "GU", zip: "96910")
        operator = User.create!(id: OPERATOR_ID, organization: company.organization, company: company,
          clerk_id: principal.fetch(:clerk_id), email: principal.fetch(:email), name: principal.fetch(:name),
          role: "accountant", active: true, invitation_status: "accepted")
        CompanyAssignment.create!(user: operator, company: company)
        maintainer = User.create!(id: MAINTAINER_ID, organization: company.organization, company: company,
          clerk_id: "pending_#{FIXTURE}", email: "manual-acceptance-maintainer@example.test",
          name: "Acceptance Fixture Maintainer (No Login)", role: "manager", active: false, invitation_status: "pending")
        template = TimeTrackingSource.find(910_001)
        source = TimeTrackingSource.create!(id: OPERATOR_ID, company: company, name: "SYNTHETIC AIRE Manual Acceptance",
          source_type: "aire_services", base_url: template.base_url, shared_secret: template.shared_secret, active: true,
          expected_source_instance_id: identity.source_instance_id, source_protocol: identity.protocol,
          source_protocol_version: identity.protocol_version, source_capabilities: identity.capabilities,
          identity_verified_at: Time.current)
        raise GuardError, "New company unexpectedly has historical payroll" if source.historical_reconciliation_required?
        schedule = CompanyPaySchedule.create!(company: company, frequency: "semimonthly", period_rule: "semimonthly",
          pay_date_rule: "semimonthly_15th_and_month_end", timezone: "Pacific/Guam", source: "operator_confirmed",
          confirmation_status: "confirmed", confirmed_by: maintainer, confirmed_at: Time.current, notes: PURPOSE,
          effective_on: period_start, payroll_cutoff_days_before: 7, payroll_cutoff_at_minutes: 1_020,
          time_tracking_cutoff_rule: "after_previous_regular_payday", time_tracking_cutoff_days: 7)
        workweek = CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0,
          timezone: "Pacific/Guam", source: "operator_confirmed", confirmation_status: "confirmed",
          confirmed_by: maintainer, confirmed_at: Time.current, notes: PURPOSE, effective_on: period_start)
        employee = Employee.create!(id: EMPLOYEE_ID, company: company, first_name: "Synthetic", last_name: "Manual Acceptance",
          email: "synthetic-manual-acceptance@example.test", ssn_encrypted: "920-00-0101", employment_type: "hourly",
          pay_rate: 25, pay_frequency: "semimonthly", status: "active", filing_status: "single", allowances: 0,
          additional_withholding: 0, retirement_rate: 0, roth_retirement_rate: 0, hire_date: period_start,
          address_line1: "1 Synthetic Acceptance Lane", city: "Hagåtña", state: "GU", zip: "96910",
          payment_delivery_method: "paper_check")
        EmployeeWageRate.create!(employee: employee, label: "Synthetic Acceptance", rate: 25, active: true, is_primary: true)
        EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: maintainer)
        employee.employee_document_requirements.find_each do |requirement|
          EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: maintainer,
            attributes: { status: "waived", review_note: PURPOSE, lock_version: requirement.lock_version }).call!
        end
        TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee,
          source_user_id: EMPLOYEE_ID.to_s, source_user_uuid: EMPLOYEE_UUID)
        PayPeriod.create!(id: OPERATOR_ID, company: company, company_pay_schedule: schedule, company_workweek: workweek,
          start_date: period_start, end_date: period_end, pay_date: period_end.end_of_month, status: "draft",
          cycle: "regular", run_purpose: "adjustment", run_purpose_source: "operator_selected", notes: PURPOSE)
      end

      def create_aire!
        names = principal.fetch(:name).split(" ", 2)
        User.create!(id: OPERATOR_ID, clerk_id: principal.fetch(:clerk_id), email: principal.fetch(:email),
          first_name: names.first, last_name: names.last, role: "admin", is_active: true,
          personal_access_enabled: true, profile_source: "clerk", time_tracking_enabled: false, kiosk_enabled: false)
        employee = User.create!(id: EMPLOYEE_ID, clerk_id: "local_#{FIXTURE}", email: "synthetic-manual-acceptance@example.test",
          payroll_integration_uuid: EMPLOYEE_UUID, first_name: "Synthetic", last_name: "Manual Acceptance", role: "employee",
          is_active: true, personal_access_enabled: false, profile_source: "local", time_tracking_enabled: true,
          kiosk_enabled: true, kiosk_pin: SecureRandom.random_number(10**8).to_s.rjust(8, "0"))
        category = TimeCategory.create!(id: EMPLOYEE_ID, name: "Synthetic Acceptance", key: "synthetic_manual_acceptance",
          description: PURPOSE, hourly_rate_cents: 2_500, is_active: true)
        UserTimeCategory.create!(user: employee, time_category: category, hourly_rate_cents: 2_500)
        zone = ActiveSupport::TimeZone["Pacific/Guam"]
        start_time = zone.local(work_date.year, work_date.month, work_date.day, 8)
        TimeEntry.create!(id: ENTRY_ID, user: employee, time_category: category, work_date: work_date,
          start_time: start_time, end_time: start_time + 4.hours, break_minutes: 0, status: "completed",
          entry_method: "manual", clock_source: "admin", approval_status: "pending", overtime_status: "none",
          description: "#{PURPOSE}; authored now for retrospective manual review; no historical cutoff claim")
      end

      def period_start
        Date.new(2026, 9, 1)
      end

      def period_end
        Date.new(2026, 9, 15)
      end

      def work_date
        Date.new(2026, 9, 10)
      end

      def protected_rows
        fixture_tables.to_h do |table|
          ids = connection.select_values("SELECT id FROM #{connection.quote_table_name(table)} ORDER BY id")
          [ table, { ids: ids, digest: table_digest(table, ids) } ]
        end
      end

      def table_digest(table, ids)
        return Digest::SHA256.hexdigest("[]") if ids.empty?

        quoted_ids = ids.map { |id| connection.quote(id) }.join(",")
        serialized = connection.select_value("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id)::text, '[]') FROM #{connection.quote_table_name(table)} t WHERE id IN (#{quoted_ids})")
        Digest::SHA256.hexdigest(serialized)
      end

      def assert_protected_rows!(original)
        unless original.all? { |table, row| table_digest(table, row.fetch(:ids)) == row.fetch(:digest) }
          raise GuardError, "Existing staging records changed; rolling back the additive fixture"
        end
      end
  end
end
