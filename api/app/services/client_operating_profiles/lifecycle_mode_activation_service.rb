# frozen_string_literal: true

module ClientOperatingProfiles
  # Activates due future-dated client_managed operating profile rows under
  # Company.lock by re-running all §5.1 preflight checks fail-closed (§4.1, §5.1).
  #
  # - If all preflights pass: stamps lifecycle_mode_activated_at, clears any
  #   prior failure metadata, and records client_operating_profile.lifecycle_mode_activated.
  # - If any preflight fails: leaves lifecycle_mode_activated_at = nil (staying
  #   fail-closed in approval_first), stamps lifecycle_mode_activation_failed_at
  #   and structured lifecycle_mode_activation_blockers, records
  #   client_operating_profile.lifecycle_mode_activation_blocked, and notifies
  #   when the PR 4 notification hook is present.
  class LifecycleModeActivationService
    class ModeChanged < StandardError; end

    ACTIVATED_AUDIT_ACTION = "client_operating_profile.lifecycle_mode_activated"
    BLOCKED_AUDIT_ACTION = "client_operating_profile.lifecycle_mode_activation_blocked"

    Result = Data.define(:status, :profile, :preflight) do
      def activated?
        status == :activated
      end

      def already_active?
        status == :already_active
      end

      def blocked?
        status == :blocked
      end
    end

    def self.ensure_attempted!(company, as_of: PayrollBusinessClock.today)
      return nil if company.blank? || !company.persisted?
      return nil if CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")

      today = as_of.to_date
      profile = ClientOperatingProfile.for_date(company.id, today)
      return nil unless unattempted_due_profile?(profile, today)

      activate!(company: company, actor: nil, as_of: today)
    end

    def self.activate!(company:, actor: nil, as_of: PayrollBusinessClock.today)
      new(company: company, actor: actor, as_of: as_of).activate!
    end

    def self.unattempted_due_profile?(profile, as_of = PayrollBusinessClock.today)
      due_profile?(profile, as_of) && profile.lifecycle_mode_activation_failed_at.nil?
    end

    def self.due_profile?(profile, as_of = PayrollBusinessClock.today)
      profile.present? &&
        profile.persisted? &&
        profile.effective_on <= as_of.to_date &&
        profile.client_portal_enabled? &&
        profile.option_value("client_portal.employee_lifecycle_mode") == "client_managed" &&
        profile.lifecycle_mode_activated_at.nil?
    end

    def initialize(company:, actor: nil, as_of: PayrollBusinessClock.today)
      @company = company
      @actor = actor
      @as_of = as_of.to_date
    end

    def activate!
      if CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")
        return Result.new(status: :not_applicable, profile: nil, preflight: nil)
      end

      @company.with_lock(requires_new: true) do
        profile = ClientOperatingProfile.for_date(@company.id, @as_of)
        unless profile&.persisted? && profile.client_portal_enabled? &&
            profile.option_value("client_portal.employee_lifecycle_mode") == "client_managed"
          return Result.new(status: :not_applicable, profile: profile, preflight: nil)
        end

        if profile.lifecycle_mode_activated_at.present?
          return Result.new(status: :already_active, profile: profile, preflight: nil)
        end

        preflight = LifecycleModePreflight.evaluate(@company)
        if preflight.passed?
          profile.update!(
            lifecycle_mode_activated_at: Time.current,
            lifecycle_mode_activation_failed_at: nil,
            lifecycle_mode_activation_blockers: {}
          )
          record_audit!(
            action: ACTIVATED_AUDIT_ACTION,
            profile: profile,
            metadata: {
              version: profile.version,
              effective_on: profile.effective_on.iso8601
            }
          )
          Result.new(status: :activated, profile: profile, preflight: preflight)
        else
          profile.update!(
            lifecycle_mode_activated_at: nil,
            lifecycle_mode_activation_failed_at: Time.current,
            lifecycle_mode_activation_blockers: preflight.blockers_hash
          )
          record_audit!(
            action: BLOCKED_AUDIT_ACTION,
            profile: profile,
            metadata: {
              version: profile.version,
              effective_on: profile.effective_on.iso8601,
              blockers: preflight.blockers_hash,
              errors: preflight.error_messages
            }
          )
          # TODO(PR4): PR 4 implements real notification delivery here (safe
          # because on-demand activation runs in its own committed transaction
          # before client write transactions).
          PortalNotifications.lifecycle_mode_activation_blocked!(profile, actor: acting_user)
          Result.new(status: :blocked, profile: profile, preflight: preflight)
        end
      end
    end

    private

    def acting_user
      @actor if @actor.is_a?(User)
    end

    def audit_actor
      return nil if acting_user

      @actor || Current.actor || AuditActor.system_job(self.class.name)
    end

    def record_audit!(action:, profile:, metadata:)
      AuditLog.record!(
        user: acting_user,
        actor: audit_actor,
        company_id: @company.id,
        organization_id: @company.organization_id,
        action: action,
        record_type: profile.class.name,
        record_id: profile.id,
        subject_name: @company.name,
        event_category: "configuration",
        metadata: metadata
      )
    end
  end
end
