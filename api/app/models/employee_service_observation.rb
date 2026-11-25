# frozen_string_literal: true

# What the employee service last reported about its own process (M4-9d).
# Payroll web reads it for the switch readiness checks, because it can't see
# the employee service's settings. The employee service writes it when its
# dependency health check runs (Health::DependenciesController).
class EmployeeServiceObservation < ApplicationRecord
  SERVICE = "employee_web"
  # An observation older than this doesn't count as a healthy service.
  FRESH_FOR = 5.minutes
  # Health checks can run every few seconds; record at most this often.
  WRITE_INTERVAL = 30.seconds

  validates :service, inclusion: { in: [ SERVICE ] }
  validates :rls_guard_mode, inclusion: { in: RlsConfiguration::MODES }

  def self.current
    find_by(service: SERVICE)
  end

  def fresh?(now: Time.current)
    observed_at.present? && observed_at >= now - FRESH_FOR && observed_at <= now + 1.minute
  end

  def rls_guard_raise?
    rls_guard_mode == "raise" && rls_runtime_role_verified
  end

  # Called on the employee service only. Records its configuration and the
  # dependency result, at most once per WRITE_INTERVAL. Never raises: a
  # failed write leaves the last observation to go stale.
  def self.record_current_process!(dependencies_healthy:, env: ENV, now: Time.current,
    readiness: -> { ProductionReadiness.new(env: env) })
    return false unless env.fetch("APP_PROCESS_ROLE", ProcessRole::ALL) == ProcessRole::EMPLOYEE_WEB

    existing = current
    return false if existing&.observed_at && existing.observed_at > now - WRITE_INTERVAL && existing.observed_at <= now

    service_checks = readiness.call.employee_service_checks
    attributes = {
      observed_at: now,
      revision: env.fetch("RENDER_GIT_COMMIT", env.fetch("GIT_COMMIT", "unknown")).to_s.first(80),
      process_role: ProcessRole::EMPLOYEE_WEB,
      rls_guard_mode: RlsConfiguration::MODES.include?(RlsConfiguration.mode(env)) ? RlsConfiguration.mode(env) : "off",
      rls_runtime_role_verified: runtime_role_verified?,
      require_mfa: MfaPolicy.enabled?(env: env),
      mfa_evidence_recorded: RolloutEnvironment.mfa_evidence_recorded?(env),
      authorized_parties_valid: RolloutEnvironment.clerk_authorized_parties_valid?(env),
      dependencies_healthy: dependencies_healthy == true,
      service_checks_passed: service_checks.all?(&:passed),
      failed_checks: service_checks.reject(&:passed).map(&:name)
    }
    upsert(attributes.merge(service: SERVICE), unique_by: :service, update_only: attributes.keys)
    true
  rescue StandardError => error
    Rails.logger.warn("[EmployeeServiceObservation] could not record: #{error.class}")
    false
  end

  def self.runtime_role_verified?
    ActiveRecord::Base.connection_pool.with_connection { |connection| RlsDatabase.verify_runtime!(connection) } == true
  rescue StandardError
    false
  end
  private_class_method :runtime_role_verified?
end
