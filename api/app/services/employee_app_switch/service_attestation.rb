# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"

module EmployeeAppSwitch
  # The employee service's signed statement about its own process, returned
  # in the live /health/dependencies response (M4-9d). Payroll web can't see
  # the employee service's settings, so readiness asks it directly: it sends
  # a fresh nonce with an HMAC proving it holds the shared secret, and the
  # employee service answers with its guard mode, database role, sign-in
  # settings and deploy revision, signed with the same secret
  # (EMPLOYEE_SERVICE_ATTESTATION_SECRET on both services). A response that
  # isn't signed, is for another nonce, is stale, or doesn't come from the
  # employee_web process counts as no answer.
  module ServiceAttestation
    SECRET_ENV = "EMPLOYEE_SERVICE_ATTESTATION_SECRET"
    NONCE_HEADER = "X-Employee-Attestation-Nonce"
    PROOF_HEADER = "X-Employee-Attestation-Proof"
    NONCE_PATTERN = /\A[0-9a-f]{64}\z/
    HEX_PATTERN = /\A[0-9a-f]{64}\z/
    MAX_AGE = 60.seconds
    MIN_SECRET_LENGTH = 32

    Observation = Data.define(
      :revision, :process_role, :rls_guard_mode, :rls_runtime_role_verified, :rls_kill_switch_bypass, :require_mfa,
      :mfa_evidence_recorded, :authorized_parties_valid, :dependencies_healthy, :service_checks_passed,
      :failed_checks, :issued_at
    ) do
      def rls_guard_raise?
        rls_guard_mode == "raise" && rls_runtime_role_verified == true && rls_kill_switch_bypass == false
      end
    end

    module_function

    def secret(env = ENV)
      value = env[SECRET_ENV].to_s
      value.length >= MIN_SECRET_LENGTH ? value : nil
    end

    def configured?(env = ENV)
      secret(env).present?
    end

    def new_nonce
      SecureRandom.hex(32)
    end

    def request_headers(nonce, env: ENV)
      key = secret(env)
      return {} unless key

      { NONCE_HEADER => nonce, PROOF_HEADER => hmac(key, "request:#{nonce}") }
    end

    # Employee service side: true when the caller proved it holds the secret.
    def valid_request?(nonce, proof, env: ENV)
      key = secret(env)
      return false unless key && nonce.is_a?(String) && NONCE_PATTERN.match?(nonce) && proof.is_a?(String) &&
        HEX_PATTERN.match?(proof)

      ActiveSupport::SecurityUtils.secure_compare(proof, hmac(key, "request:#{nonce}"))
    end

    # Employee service side: the signed statement, or nil when this isn't the
    # employee_web process or no secret is set.
    def sign(nonce:, dependencies_healthy:, env: ENV, now: Time.current,
      readiness: -> { ProductionReadiness.new(env: env) })
      key = secret(env)
      return nil unless key && env.fetch("APP_PROCESS_ROLE", ProcessRole::ALL) == ProcessRole::EMPLOYEE_WEB

      service_checks = readiness.call.employee_service_checks
      mode = RlsConfiguration.mode(env)
      role_verified, bypass = process_database_facts
      statement = JSON.generate(
        nonce: nonce,
        issued_at: now.utc.iso8601,
        service: "employee_web",
        process_role: ProcessRole::EMPLOYEE_WEB,
        revision: env.fetch("RENDER_GIT_COMMIT", env.fetch("GIT_COMMIT", "unknown")).to_s.first(80),
        rls_guard_mode: RlsConfiguration::MODES.include?(mode) ? mode : "off",
        rls_runtime_role_verified: role_verified,
        rls_kill_switch_bypass: bypass,
        require_mfa: MfaPolicy.enabled?(env: env),
        mfa_evidence_recorded: RolloutEnvironment.mfa_evidence_recorded?(env),
        authorized_parties_valid: RolloutEnvironment.clerk_authorized_parties_valid?(env),
        dependencies_healthy: dependencies_healthy == true,
        service_checks_passed: service_checks.all?(&:passed),
        failed_checks: service_checks.reject(&:passed).map(&:name).first(10)
      )
      { statement: statement, signature: hmac(key, "response:#{statement}") }
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch::ServiceAttestation] could not sign: #{error.class}")
      nil
    end

    # [restricted role verified, kill switch bypassing (nil if unknown)],
    # read on this process's own connection.
    def process_database_facts
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        verified = begin
          RlsDatabase.verify_runtime!(connection) == true
        rescue StandardError
          false
        end
        [ verified, Enforcement.kill_switch_bypass(connection) ]
      end
    rescue StandardError
      [ false, nil ]
    end

    # Payroll side: the Observation, or [nil, reason].
    def verify(body, nonce:, env: ENV, now: Time.current)
      key = secret(env)
      return [ nil, :not_configured ] unless key

      parsed = JSON.parse(body.to_s)
      attestation = parsed.is_a?(Hash) ? parsed["attestation"] : nil
      return [ nil, :unsigned ] unless attestation.is_a?(Hash)

      statement = attestation["statement"]
      signature = attestation["signature"]
      return [ nil, :unsigned ] unless statement.is_a?(String) && signature.is_a?(String) && HEX_PATTERN.match?(signature)
      return [ nil, :bad_signature ] unless ActiveSupport::SecurityUtils.secure_compare(signature, hmac(key, "response:#{statement}"))

      data = JSON.parse(statement)
      return [ nil, :bad_signature ] unless data.is_a?(Hash) && data["nonce"] == nonce
      return [ nil, :wrong_process ] unless data["process_role"] == ProcessRole::EMPLOYEE_WEB && data["service"] == "employee_web"

      issued_at = Time.iso8601(data["issued_at"].to_s)
      return [ nil, :stale ] unless issued_at.between?(now - MAX_AGE, now + MAX_AGE)

      [ observation_from(data, issued_at), nil ]
    rescue JSON::ParserError, ArgumentError, TypeError
      [ nil, :unsigned ]
    end

    def observation_from(data, issued_at)
      Observation.new(
        revision: data["revision"].to_s.first(80), process_role: data["process_role"],
        rls_guard_mode: RlsConfiguration::MODES.include?(data["rls_guard_mode"]) ? data["rls_guard_mode"] : "off",
        rls_runtime_role_verified: data["rls_runtime_role_verified"] == true,
        rls_kill_switch_bypass: [ true, false ].include?(data["rls_kill_switch_bypass"]) ? data["rls_kill_switch_bypass"] : nil,
        require_mfa: data["require_mfa"] == true, mfa_evidence_recorded: data["mfa_evidence_recorded"] == true,
        authorized_parties_valid: data["authorized_parties_valid"] == true,
        dependencies_healthy: data["dependencies_healthy"] == true, service_checks_passed: data["service_checks_passed"] == true,
        failed_checks: Array(data["failed_checks"]).map(&:to_s).first(10), issued_at: issued_at
      )
    end

    def hmac(key, message)
      OpenSSL::HMAC.hexdigest("SHA256", key, message)
    end
  end
end
