# frozen_string_literal: true

# Activates scheduled future-dated Client-managed employee lifecycle profiles
# once their effective_on date arrives (§4.1, §5.1). Runs across all companies
# on Guam midnight and hourly as a backstop; live writes also attempt due
# activations on demand under Company.lock.
class ActivateScheduledLifecycleModesJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(as_of: nil)
    return if CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")

    date = as_of.present? ? Date.iso8601(as_of.to_s) : PayrollBusinessClock.today
    Current.with_isolated_actor(AuditActor.system_job(self)) { activate_due_companies(date) }
  end

  private

  def activate_due_companies(as_of)
    failures = due_company_ids(as_of).filter_map do |company_id|
      company = Company.find_by(id: company_id)
      next unless company

      ClientOperatingProfiles::LifecycleModeActivationService.activate!(
        company: company,
        as_of: as_of,
        allow_retry_blocked: false
      )
      nil
    rescue StandardError => error
      Rails.logger.error("Scheduled lifecycle mode activation failed for company_id=#{company_id} (#{error.class})")
      Rails.error.report(error, handled: true, context: { company_id: company_id })
      company_id
    end
    raise "Scheduled lifecycle mode activation failed for company IDs: #{failures.join(', ')}" if failures.any?
  end

  def due_company_ids(as_of)
    ClientOperatingProfile
      .active_on(as_of)
      .reorder(nil)
      .where(client_portal_enabled: true, lifecycle_mode_activated_at: nil, lifecycle_mode_activation_failed_at: nil)
      .where("options -> 'client_portal' ->> 'employee_lifecycle_mode' = ?", "client_managed")
      .distinct
      .pluck(:company_id)
      .sort
  end
end
