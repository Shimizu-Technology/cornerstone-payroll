# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module EmployeeAppSwitch
  # The M4-9 checks every turn-on must pass, named in plain language. Real
  # companies need every check, including database row-level security with
  # the global kill switch not bypassing. A demo company named in an
  # in-effect early-access window may have only the database check waived,
  # only in the intended shadow state, and only while the employee service's
  # guard runs in raise mode (docs/DEMO_COMPANY_PLAN_2026-11-25.md §4).
  # While REQUIRE_MFA is off, the two-step check is advisory (waived) for
  # every company (mfa_check).
  #
  # What the employee service runs comes from its live, signed health
  # response (ServiceAttestation), read once per check, never from a
  # stored report.
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
      database_state: -> { Readiness.database_state },
      ping: -> { Readiness.ping_employee_service(env) },
      window: nil)
      @company = company
      @env = env
      @now = now
      @today = today
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

    # Actual policy and kill-switch state, read on this process.
    def self.database_state
      Enforcement.database_state
    end

    # Asks the employee service for its live dependency health and its signed
    # statement about its own process. EMPLOYEE_API_URL is its base URL
    # (configuration only; HTTPS in production). Redirects are never
    # followed: anything but the answer itself counts as no answer.
    def self.ping_employee_service(env = ENV, now: Time.current, open_timeout: 2, read_timeout: 4)
      uri = employee_health_uri(env["EMPLOYEE_API_URL"])
      return { configured: false, ok: false, observation: nil, attestation_error: :not_configured } unless uri

      nonce = ServiceAttestation.new_nonce
      headers = { "Accept" => "application/json" }.merge(ServiceAttestation.request_headers(nonce, env: env))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: open_timeout,
        read_timeout: read_timeout) do |http|
        http.request(Net::HTTP::Get.new(uri, headers))
      end
      code = response.code.to_i
      observation, error = [ 200, 503 ].include?(code) ? ServiceAttestation.verify(response.body, nonce: nonce, env: env, now: now) : [ nil, :unsigned ]
      { configured: true, ok: code == 200 && health_status(response.body) == "ok", observation: observation, attestation_error: error }
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch] employee service ping failed: #{error.class}")
      { configured: true, ok: false, observation: nil, attestation_error: :unreachable }
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

    # The verified statement from this check's own ping, or nil.
    def fresh_observation
      ping[:observation]
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
      case ping[:attestation_error]
      when :not_configured
        "EMPLOYEE_SERVICE_ATTESTATION_SECRET isn't set on Payroll, so the employee service's settings can't be verified."
      when :bad_signature, :wrong_process
        "The employee service's health response didn't verify (signature, nonce or process), so it doesn't count."
      when :stale
        "The employee service's signed health response is too old or its clock is off."
      else
        "The employee service didn't return a signed health response (is EMPLOYEE_SERVICE_ATTESTATION_SECRET set on it?)."
      end
    end

    def company_check
      check(:company, "This is a live client or a demo company", EmployeeAppSwitch.eligible_company?(company),
        "Test workspaces and inactive companies can't use the employee app.")
    end

    MFA_OFF_DETAIL = "Two-step sign-in isn't required yet; it will be turned on for everyone before real " \
      "employees use the app."

    # REQUIRE_MFA off (Clerk Free, until the Pro rollout): advisory for every
    # company, demo and live alike, shown as waived; step-up is then a fresh
    # first factor. With it on, both services must require it with recorded
    # evidence, exactly as before.
    def mfa_check
      name = "Two-step sign-in is required (REQUIRE_MFA=true with the two-step claim)"
      return mfa_off_check(name) unless MfaPolicy.enabled?(env: env)

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

    def mfa_off_check(name)
      Check.new(key: "mfa", name: name, status: "waived", detail: MFA_OFF_DETAIL)
    end

    def rls_guard_check
      name = "The employee service refuses any database read without a company (RLS guard in raise mode)"
      obs = fresh_observation
      detail = if obs.nil?
        unreported
      elsif obs.rls_guard_mode != "raise"
        "The employee service's guard is set to #{obs.rls_guard_mode}, not raise."
      elsif !obs.rls_runtime_role_verified
        "The employee service isn't connected as the restricted database role."
      else
        "The employee service sees the RLS kill switch bypassing (or can't read it), which silences its guard."
      end
      check(:rls_guard, name, obs&.rls_guard_raise? == true, detail)
    end

    def rls_database_check
      name = "The database enforces company separation (row-level security on)"
      if database_state[:enforced]
        # Verified enforcement retires early access for good.
        Enforcement.retire_windows!
        return check(:rls_database, name, true, nil)
      end

      if demo_exception_applies?
        return Check.new(key: "rls_database", name: name, status: "waived",
          detail: "Waived for this demo company through #{window.expires_on.iso8601} by the " \
            "#{EmployeeAppEarlyAccessWindow::NAME.downcase} rule, while the employee service's guard is in raise mode.")
      end

      check(:rls_database, name, false, rls_database_detail)
    end

    def rls_database_detail
      detail = case database_state[:phase]
      when "bypassed" then "The RLS kill switch is bypassing, so the database isn't enforcing row-level security."
      when "unknown" then "The database's row-level security state (or its kill switch) can't be read, so it doesn't count."
      else "The database isn't enforcing row-level security yet (#{database_state[:phase].to_s.tr('_', ' ')})."
      end
      demo? ? "#{detail} #{demo_exception_detail}" : detail
    end

    def demo_exception_applies?
      demo? && window&.covers?(company, today: @today) && Enforcement.shadow?(database_state) &&
        fresh_observation&.rls_guard_raise? == true
    end

    def demo_exception_detail
      if window.nil? || !Array(window.company_ids).include?(company.id)
        "No demo early-access window covers this company."
      elsif window.retired?
        "The demo early-access window retired when the database began enforcing row-level security."
      elsif !window.in_effect?(today: @today)
        "The demo early-access window ended on #{window.expires_on.iso8601}."
      elsif !Enforcement.shadow?(database_state)
        "The demo early-access rule applies only in shadow mode with the kill switch off."
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
      obs = fresh_observation
      {
        reported: obs.present?,
        fresh: obs.present?,
        verified: obs.present?,
        observed_at: obs&.issued_at&.utc&.iso8601,
        revision: obs&.revision,
        rls_guard_mode: obs&.rls_guard_mode,
        rls_runtime_role_verified: obs&.rls_runtime_role_verified == true,
        rls_kill_switch_bypass: obs&.rls_kill_switch_bypass,
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
