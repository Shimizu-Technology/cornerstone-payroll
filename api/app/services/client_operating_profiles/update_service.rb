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
        authorize!
        previous = @company.client_operating_profiles.history_order.first
        unless @lock_version == (previous&.lock_version || 0)
          raise Conflict, "The operating profile changed. Reload the latest version before saving."
        end

        validate_pay_period!
        previous ||= create_baseline!
        if @effective_on <= previous.effective_on
          raise Invalid, "Effective date must be after the latest profile's start date (#{previous.effective_on})."
        end

        append_profile!(previous)
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

      @entries = @changes.keys.map do |key|
        OperatingProfileCatalog.find(key) || raise(Invalid, "Unknown operating profile setting: #{key}")
      end
    rescue Date::Error
      raise Invalid, "Enter a valid effective date."
    end

    def authorize!
      unless @actor&.payroll_access_allowed? && @actor.can_access_company?(@company.id) &&
          StaffRolePolicy.allowed?(@actor, :payroll_operations)
        raise Forbidden, "Payroll operations access to this client is required."
      end

      editable = OperatingProfileCatalog.editable_keys_for(user: @actor, company: @company)
      @entries.each do |entry|
        unless editable.include?(entry.id)
          raise Forbidden, "You do not have permission to change #{entry.label}."
        end

        if OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.include?(entry.id) && @changes.fetch(entry.id) != false
          raise Invalid, "#{entry.label} is locked until its milestone launches."
        end
      end
    end

    def validate_pay_period!
      # Company lock serializes run creation. Lock existing runs before checking
      # status so a concurrent calculation, approval or commit is visible.
      periods = @company.pay_periods.where(end_date: @effective_on..).order(:id).lock.to_a
      if periods.any? { |period| period.status.in?(%w[calculated approved committed retired_history]) || period.training_baseline? }
        raise Invalid, "This effective date would change a calculated, approved, or committed pay period."
      end

      if periods.any? { |period| period.start_date < @effective_on } ||
          periods.none? { |period| period.start_date == @effective_on && period.status == "draft" }
        raise Invalid, "The effective date must be the start of a draft pay period."
      end
    end

    def create_baseline!
      attributes = LegacyProfileBuilder.attributes_for(@company)
      # A company may have opened its first run on the day the change begins.
      # Give its legacy baseline a non-overlapping interval in that case.
      attributes[:effective_on] = [ attributes.fetch(:effective_on), @effective_on - 1 ].min
      ClientOperatingProfile.create!(attributes)
    end

    def append_profile!(previous)
      before = OperatingProfileCatalog.values_for(previous)
      after = before.merge(@changes)
      if OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS.any? { |key| after[key] != false }
        raise Invalid, "All forthcoming feature switches must be off."
      end
      errors = OperatingProfileCatalog.change_errors(after)
      raise Invalid, errors.to_sentence if errors.present?
      changed_fields = after.keys.reject { |key| after.fetch(key) == before.fetch(key) }
      raise Invalid, "Change at least one setting before saving." if changed_fields.empty?

      # Only close the preceding interval. Its effective date, settings and
      # change provenance are retained.
      previous.update!(ends_on: @effective_on - 1) if previous.ends_on.nil? || previous.ends_on >= @effective_on
      profile = @company.client_operating_profiles.create!(
        **OperatingProfileCatalog.attributes_from(after),
        effective_on: @effective_on,
        version: previous.version + 1,
        lock_version: @lock_version + 1,
        changed_by: @actor,
        reason: @reason.strip
      )
      AuditLog.record!(
        user: @actor, company_id: @company.id, organization_id: @company.organization_id,
        action: AUDIT_ACTION, record_type: profile.class.name, record_id: profile.id,
        subject_name: @company.name, event_category: "configuration",
        metadata: {
          version: profile.version, effective_on: profile.effective_on.iso8601, reason: profile.reason,
          changed_fields: changed_fields, before_values: before.slice(*changed_fields), after_values: after.slice(*changed_fields)
        }
      )
      profile
    end
  end
end
