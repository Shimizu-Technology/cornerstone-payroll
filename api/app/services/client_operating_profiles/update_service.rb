# frozen_string_literal: true

module ClientOperatingProfiles
  class UpdateService
    class Invalid < StandardError; end
    class Forbidden < StandardError; end
    class Conflict < StandardError; end

    AUDIT_ACTION = "client_operating_profile.update"

    def initialize(company:, actor:, effective_on:, changes:, reason:, lock_version:)
      @company = company
      @actor = actor
      @effective_on = effective_on
      @changes = changes
      @reason = reason
      @lock_version = lock_version
    end

    def call
      validate_request!
      @company.with_lock(requires_new: true) do
        reload_actor!
        authorize!
        previous = @company.client_operating_profiles.history_order.first
        unless @lock_version == (previous&.lock_version || 0)
          raise Conflict, "The operating profile changed. Reload the latest version before saving."
        end

        dates = EffectiveDates.new(company: @company, latest: previous, changed_keys: @changes.keys)
        dates.validate!(@effective_on)
        previous ||= create_baseline!
        save_profile!(previous, amend: dates.amend?(@effective_on))
      end
    end

    private

    def validate_request!
      unless @effective_on.is_a?(String) && @effective_on.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        raise Invalid, "Enter an effective date in YYYY-MM-DD format."
      end
      @effective_on = Date.iso8601(@effective_on)
      raise Invalid, "Provide a valid lock_version." unless @lock_version.is_a?(Integer) && @lock_version >= 0
      raise Invalid, "Enter a reason for the change." unless @reason.is_a?(String) && @reason.strip.present?
      raise Invalid, "Provide at least one setting to change." unless @changes.is_a?(Hash) && @changes.present?

      @changes = @changes.stringify_keys
      @entries = @changes.keys.map do |key|
        OperatingProfileCatalog.find(key) || raise(Invalid, "Unknown operating profile setting: #{key}")
      end
    rescue Date::Error
      raise Invalid, "Enter a valid effective date."
    end

    def reload_actor!
      @actor = User.lock.find_by(id: @actor&.id)
      @company.company_assignments.where(user_id: @actor&.id).lock.load
    end

    def authorize!
      unless @actor&.payroll_access_allowed? && @actor.can_access_company?(@company.id) &&
          StaffRolePolicy.allowed?(@actor, :payroll_operations)
        raise Forbidden, "Payroll operations access to this client is required."
      end

      unless TestWorkspaceAccessPolicy.allowed?(user: @actor, company: @company, request_method: "PATCH",
          capability: :payroll_operations)
        raise Forbidden, @company.demo? ? Company::DEMO_ACCESS_DENIED_MESSAGE : "Your test workspace access does not allow this action."
      end
      if @company.test_workspace? && !@company.test_workspace_ready?
        raise Conflict, "This test workspace is still being prepared."
      end

      editable = OperatingProfileCatalog.editable_keys_for(user: @actor, company: @company)
      @entries.each do |entry|
        unless editable.include?(entry.id)
          raise Forbidden, "You do not have permission to change #{entry.label}."
        end

        if OperatingProfileCatalog.locked_milestone_for(entry)
          locked_default = OperatingProfileCatalog.locked_default_for(entry.id)
          if !OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.include?(entry.id) || @changes.fetch(entry.id) != locked_default
            if EmployeeAppSwitch::KEYS.include?(entry.id)
              raise Invalid, "#{entry.label} is locked here. Turn it on from the Employee app switch screen."
            end
            raise Invalid, "#{entry.label} is locked until its milestone launches."
          end
        end
      end
    end

    def create_baseline!
      attributes = LegacyProfileBuilder.attributes_for(@company)
      # A company may have opened its first run on the day the change begins.
      # Give its legacy baseline a non-overlapping interval in that case.
      attributes[:effective_on] = [ attributes.fetch(:effective_on), @effective_on - 1 ].min
      ClientOperatingProfile.create!(attributes)
    end

    def save_profile!(previous, amend:)
      before = OperatingProfileCatalog.values_for(previous)
      after = before.merge(@changes)
      # A switch the Employee app switch turned on (M4-9d) may stay on through
      # an ordinary profile edit; every other forthcoming switch stays at its locked default.
      if OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.any? { |key| after[key] != OperatingProfileCatalog.locked_default_for(key) && !switch_kept_on?(key, before, after) }
        raise Invalid, "All forthcoming feature switches must be off."
      end
      errors = OperatingProfileCatalog.change_errors(after)
      raise Invalid, errors.to_sentence if errors.present?
      changed_fields = after.keys.reject { |key| after.fetch(key) == before.fetch(key) }
      raise Invalid, "Change at least one setting before saving." if changed_fields.empty?

      lifecycle_attrs = resolve_lifecycle_activation_attributes!(previous: previous, before: before, after: after)
      attributes = OperatingProfileCatalog.attributes_from(after)
        .merge(lifecycle_attrs)
        .merge(changed_by: @actor, reason: @reason.strip)
      profile = if amend
        previous.update!(**attributes)
        previous
      else
        append_profile!(previous, attributes)
      end
      AuditLog.record!(
        user: @actor, company_id: @company.id, organization_id: @company.organization_id,
        action: AUDIT_ACTION, record_type: profile.class.name, record_id: profile.id,
        subject_name: @company.name, event_category: "configuration",
        metadata: {
          version: profile.version, effective_on: profile.effective_on.iso8601, reason: profile.reason,
          amended: amend, changed_fields: changed_fields, before_values: before.slice(*changed_fields), after_values: after.slice(*changed_fields)
        }
      )
      profile
    end

    def resolve_lifecycle_activation_attributes!(previous:, before:, after:)
      mode = after["client_portal.employee_lifecycle_mode"]
      unless mode == "client_managed" && after["client_portal_enabled"] == true
        return {
          lifecycle_mode_activated_at: nil,
          lifecycle_mode_activation_failed_at: nil,
          lifecycle_mode_activation_blockers: {}
        }
      end

      already_activated = previous.persisted? &&
        before["client_portal_enabled"] == true &&
        before["client_portal.employee_lifecycle_mode"] == "client_managed" &&
        previous.lifecycle_mode_activated_at.present?
      if already_activated
        return {
          lifecycle_mode_activated_at: previous.lifecycle_mode_activated_at,
          lifecycle_mode_activation_failed_at: nil,
          lifecycle_mode_activation_blockers: {}
        }
      end

      preflight = LifecycleModePreflight.evaluate(@company)
      raise Invalid, preflight.error_messages.join(" ") unless preflight.passed?

      {
        lifecycle_mode_activated_at: (@effective_on <= PayrollBusinessClock.today ? Time.current : nil),
        lifecycle_mode_activation_failed_at: nil,
        lifecycle_mode_activation_blockers: {}
      }
    end

    def switch_kept_on?(key, before, after)
      EmployeeAppSwitch::KEYS.include?(key) && before[key] == true && after[key] == true
    end

    def append_profile!(previous, attributes)
      # A backfilled baseline can already start on the first draft date. Retain
      # its settings and provenance on the preceding day, as for a lazy baseline.
      if previous.effective_on == @effective_on
        previous.update!(effective_on: @effective_on - 1, ends_on: @effective_on - 1)
      elsif previous.ends_on.nil? || previous.ends_on >= @effective_on
        previous.update!(ends_on: @effective_on - 1)
      end

      @company.client_operating_profiles.create!(
        **attributes,
        effective_on: @effective_on,
        version: previous.version + 1,
        lock_version: @lock_version + 1
      )
    end
  end
end
