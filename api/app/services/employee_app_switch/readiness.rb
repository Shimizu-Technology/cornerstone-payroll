# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module EmployeeAppSwitch
  # The M4-9 checks every turn-on must pass, named in plain language. Real
  # companies need every check, including database row-level security. A
  # demo company named in an in-effect early-access window may have only the
  # database check waived, and only while the employee service's guard runs
  # in raise mode (docs/DEMO_COMPANY_PLAN_2026-11-25.md §4).
  class Readiness
    Check = Data.define(:key, :name, :status, :detail) do
      def blocking?
        status == "failed"
      end

      def as_json(*)
        { key: key, name: name, status: status, detail: detail }
      end
    end

    PLATFORM_CHECKS = %i[
      company mfa rls_guard rls_database authorized_parties subdomain employee_service
    ].freeze

    def initialize(company:, env: ENV, now: Time.current, today: PayrollBusinessClock.date_for(now),
      observation: -> { EmployeeServiceObservation.current },
      database_state: -> { Readiness.database_state },
      ping: -> { Readiness.ping_employee_service(env) },
      window: nil)
      @company = company
      @env = env
      @now = now
      @today = today
      @observation_source = observation
      @database_state_source = database_state
      @ping_source = ping
      @window_source = window || -> { EmployeeAppEarlyAccessWindow.current_for(company.organization_id) }
    end

    def checks_for(key)
      counsel = SWITCHES.fetch(key).fetch(:counsel)
      platform_checks + counsel.map { |kind| counsel_check(kind) }
    end

    def failures_for(key)
      checks_for(key).select(&:blocking?)
    end

    def platform_checks
      @platform_checks ||= PLATFORM_CHECKS.map { |key| send(:"#{key}_check") }
    end

    def counsel_checks
      @counsel_checks ||= { terms: terms_check, consent: consent_check }
    end

    def exception_applied?
      platform_checks.any? { |check| check.key == "rls_database" && check.status == "waived" }
    end

    def as_json(*)
      {
        checked_at: @now.utc.iso8601,
        checks: platform_checks.map(&:as_json),
        counsel_checks: counsel_checks.transform_values(&:as_json),
        switch_checks: SWITCHES.keys.index_with { |key| failures_for(key).map(&:key) },
        observed: observed_payload,
        database: database_state,
        early_access: window_payload
      }
    end

    # Actual policy state of the protected tables, read on this process.
    def self.database_state
      rows = ActiveRecord::Base.connection_pool.with_connection { |connection| RlsDatabase.table_status(connection) }
      total = RlsTables::PROTECTED_TABLES.size
      installed = rows.size == total && rows.all? { |row| row.fetch("policy") }
      enforced_count = rows.count { |row| row.fetch("enabled") && row.fetch("forced") }
      enforced = installed && enforced_count == total
      { phase: enforced ? "enforced" : (installed ? "shadow" : "not_installed"),
        enforced: enforced, enforced_tables: enforced_count, protected_tables: total }
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch] database state unavailable: #{error.class}")
      { phase: "unknown", enforced: false, enforced_tables: 0, protected_tables: RlsTables::PROTECTED_TABLES.size }
    end

    # Asks the employee service for its dependency health, which also makes
    # it record a fresh observation. EMPLOYEE_API_URL is its base URL.
    def self.ping_employee_service(env = ENV)
      uri = employee_health_uri(env["EMPLOYEE_API_URL"])
      return { configured: false, ok: false } unless uri

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 4) do |http|
        http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
      end
      { configured: true, ok: response.code.to_i == 200 && health_status(response.body) == "ok" }
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch] employee service ping failed: #{error.class}")
      { configured: true, ok: false }
    end

    def self.health_status(body)
      parsed = JSON.parse(body.to_s)
      parsed["status"] if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def self.employee_health_uri(value)
      base = URI.parse(value.to_s.strip)
      allowed = base.is_a?(URI::HTTPS) || (!Rails.env.production? && base.is_a?(URI::HTTP))
      return unless allowed && base.host.present? && base.userinfo.nil? && base.query.nil? && base.fragment.nil?

      URI.join("#{base.to_s.delete_suffix('/')}/", "health/dependencies")
    rescue URI::InvalidURIError
      nil
    end

    private

    attr_reader :company, :env

    def observation
      return @observation if defined?(@observation)

      ping # the ping refreshes the observation first
      @observation = @observation_source.call
    end

    def fresh_observation
      observation if observation&.fresh?(now: @now)
    end

    def ping
      @ping ||= @ping_source.call
    end

    def database_state
      @database_state ||= @database_state_source.call
    end

    def window
      return @window if defined?(@window)

      @window = @window_source.call
    end

    def demo?
      company.demo?
    end

    def check(key, name, passed, detail)
      Check.new(key: key.to_s, name: name, status: passed ? "passed" : "failed", detail: passed ? nil : detail)
    end

    def unreported
      "The employee service hasn't reported its settings in the last #{EmployeeServiceObservation::FRESH_FOR.inspect}."
    end

    def company_check
      check(:company, "This is a live client or a demo company", EmployeeAppSwitch.eligible_company?(company),
        "Test workspaces and inactive companies can't use the employee app.")
    end

    def mfa_check
      name = "Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)"
      local = RolloutEnvironment.mfa_evidence_recorded?(env)
      remote = fresh_observation&.require_mfa && fresh_observation&.mfa_evidence_recorded
      detail = if !local
        "Payroll isn't requiring two-step sign-in with recorded evidence of the claim yet."
      elsif fresh_observation.nil?
        unreported
      else
        "The employee service isn't requiring two-step sign-in with recorded evidence of the claim yet."
      end
      check(:mfa, name, local && remote == true, detail)
    end

    def rls_guard_check
      name = "The employee service refuses any database read without a company (RLS guard in raise mode)"
      obs = fresh_observation
      detail = if obs.nil?
        unreported
      elsif obs.rls_guard_mode != "raise"
        "The employee service's guard is set to #{obs.rls_guard_mode}, not raise."
      else
        "The employee service isn't connected as the restricted database role."
      end
      check(:rls_guard, name, obs&.rls_guard_raise? == true, detail)
    end

    def rls_database_check
      name = "The database enforces company separation (row-level security on)"
      return check(:rls_database, name, true, nil) if database_state[:enforced]

      if demo_exception_applies?
        return Check.new(key: "rls_database", name: name, status: "waived",
          detail: "Waived for this demo company through #{window.expires_on.iso8601} by the " \
            "#{EmployeeAppEarlyAccessWindow::NAME.downcase} rule, while the employee service's guard is in raise mode.")
      end

      detail = "The database isn't enforcing row-level security yet (#{database_state[:phase].tr('_', ' ')})."
      detail += " #{demo_exception_detail}" if demo?
      check(:rls_database, name, false, detail)
    end

    def demo_exception_applies?
      demo? && window&.covers?(company, today: @today) && fresh_observation&.rls_guard_raise? == true
    end

    def demo_exception_detail
      if window.nil? || !Array(window.company_ids).include?(company.id)
        "No demo early-access window covers this company."
      elsif !window.in_effect?(today: @today)
        "The demo early-access window ended on #{window.expires_on.iso8601}."
      else
        "The demo early-access rule needs the employee service's guard in raise mode."
      end
    end

    def authorized_parties_check
      name = "Sign-in accepts only our own web addresses (CLERK_AUTHORIZED_PARTIES set)"
      local = RolloutEnvironment.clerk_authorized_parties_valid?(env)
      detail = if !local
        "Payroll's CLERK_AUTHORIZED_PARTIES isn't set to production HTTPS addresses."
      elsif fresh_observation.nil?
        unreported
      else
        "The employee service's CLERK_AUTHORIZED_PARTIES isn't set to production HTTPS addresses."
      end
      check(:authorized_parties, name, local && fresh_observation&.authorized_parties_valid == true, detail)
    end

    def subdomain_check
      slug = company.subdomain_slug.to_s
      check(:subdomain, "The company's web address (subdomain) is set", TenantSubdomainRegistry::SLUG_PATTERN.match?(slug),
        "Set this company's subdomain on its employee app settings first.")
    end

    def employee_service_check
      name = "The employee service is running and healthy"
      obs = fresh_observation
      detail = if ping[:configured] == false
        "EMPLOYEE_API_URL isn't set on Payroll, so the employee service can't be checked."
      elsif !ping[:ok]
        "The employee service didn't answer its health check."
      elsif obs.nil?
        unreported
      elsif !obs.dependencies_healthy
        "The employee service reports a dependency problem."
      else
        failed = Array(obs.failed_checks).first(3).join("; ")
        "The employee service's own checks failed#{failed.present? ? ": #{failed}" : ''}."
      end
      passed = ping[:ok] == true && obs.present? && obs.process_role == ProcessRole::EMPLOYEE_WEB &&
        obs.dependencies_healthy && obs.service_checks_passed
      check(:employee_service, name, passed, detail)
    end

    def counsel_check(kind)
      counsel_checks.fetch(kind)
    end

    def terms_check
      version = EmployeeTermsVersion.current
      name = demo? ? "Employee App Terms and Privacy Notice wording is loaded (approved, or draft for a demo)" :
        "Employee App Terms and Privacy Notice wording is approved by counsel"
      passed = version.present? && (version.approved? || demo?)
      detail = if version.nil?
        "No Employee App Terms version is loaded on the server yet."
      else
        "The loaded Terms version (#{version.version}) is still a draft awaiting counsel."
      end
      check(:terms, name, passed, detail)
    end

    def consent_check
      name = demo? ? "Electronic delivery consent wording is loaded (approved, or draft for a demo)" :
        "Electronic delivery consent wording is approved by counsel"
      disclosures = DeliveryDisclosure::KINDS.index_with { |kind| DeliveryDisclosure.current_for(kind) }
      missing = disclosures.select { |_kind, disclosure| disclosure.nil? }.keys
      drafts = disclosures.select { |_kind, disclosure| disclosure&.draft? }.keys
      passed = missing.empty? && (drafts.empty? || demo?)
      detail = if missing.any?
        "No consent wording is loaded for #{missing.map { |kind| disclosure_label(kind) }.to_sentence}."
      else
        "The #{drafts.map { |kind| disclosure_label(kind) }.to_sentence} consent wording is still a draft awaiting counsel."
      end
      check(:consent, name, passed, detail)
    end

    def disclosure_label(kind)
      kind == "w2gu" ? "W-2GU" : "pay statement"
    end

    def observed_payload
      obs = observation
      {
        reported: obs.present?,
        fresh: obs&.fresh?(now: @now) == true,
        observed_at: obs&.observed_at&.utc&.iso8601,
        revision: obs&.revision,
        rls_guard_mode: obs&.rls_guard_mode,
        rls_runtime_role_verified: obs&.rls_runtime_role_verified == true,
        dependencies_healthy: obs&.dependencies_healthy == true,
        answered_health_check: ping[:ok] == true,
        health_check_configured: ping[:configured] != false
      }
    end

    def window_payload
      return nil unless window

      {
        id: window.id,
        status: window.status(today: @today),
        expires_on: window.expires_on.iso8601,
        covers_company: window.covers?(company, today: @today),
        applied: exception_applied?
      }
    end
  end
end
