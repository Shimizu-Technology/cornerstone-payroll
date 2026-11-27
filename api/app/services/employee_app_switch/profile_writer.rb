# frozen_string_literal: true

module EmployeeAppSwitch
  # Writes switch values from today forward. These switches open or close
  # employee access and never change a payroll calculation, so unlike the
  # operating profile editor they take effect today rather than at the start
  # of a draft pay period. Call under the company lock.
  #
  # Each written row gets the editor's own audit (client_operating_profile.
  # update, with before and after values), so operating_profiles:parity
  # still explains every version:
  # - the version in effect today is split at today (a new, next-numbered
  #   version), or amended when it already starts today;
  # - a version 1 baseline that starts today moves to yesterday first, as
  #   the editor does, so the baseline itself never changes;
  # - later scheduled versions get the same values in place.
  # Turning on refuses to split ahead of a scheduled version, which would
  # number versions out of date order. Turning off always proceeds, and
  # revokes the part's activation (EmployeeAppActivation) even when no row
  # changes, so a part turned off can't come back through a profile write.
  # Locked forthcoming switches are written off on every row it touches.
  class ProfileWriter
    def self.apply!(company:, actor:, values:, reason:, today: PayrollBusinessClock.today)
      new(company: company, actor: actor, values: values, reason: reason, today: today).apply!
    end

    def initialize(company:, actor:, values:, reason:, today:)
      @company = company
      @actor = actor
      @values = values.stringify_keys.slice(*KEYS)
      @reason = reason
      @today = today
    end

    def apply!
      profiles = @company.client_operating_profiles.order(:effective_on, :version, :id).lock.to_a
      profiles = [ create_baseline! ] if profiles.empty?

      current = profiles.find { |profile| profile.effective_on <= @today && (profile.ends_on.nil? || profile.ends_on >= @today) }
      later = profiles.select { |profile| profile.effective_on > @today }
      if current.nil? && later.empty?
        raise Invalid, "This company's operating profile has no version for today. Ask support to repair it before changing the switch."
      end

      written = []
      written << write_today!(current, profiles, later) if current
      later.each { |profile| written << amend!(profile) }
      revoke_turned_off!
      written.compact
    end

    private

    def turning_on?
      @values.value?(true)
    end

    def revoke_turned_off!
      parts = @values.select { |_key, value| value == false }.keys
      return if parts.empty?

      EmployeeAppActivation.revoke!(company: @company, parts: parts, actor: @actor, reason: @reason)
    end

    def create_baseline!
      attributes = ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(@company)
      attributes[:effective_on] = [ attributes.fetch(:effective_on), @today - 1 ].min
      ClientOperatingProfile.create!(attributes)
    end

    def write_today!(current, profiles, later)
      return nil unless changes?(current)
      return amend!(current) if current.effective_on == @today && current.version > 1

      if later.any? && turning_on?
        raise Invalid, "A change to this company's operating profile is scheduled for #{later.first.effective_on.iso8601}. " \
          "Turn this on after that date."
      end

      before = OperatingProfileCatalog.values_for(current)
      ends_on = current.ends_on
      if current.effective_on == @today
        current.update!(effective_on: @today - 1, ends_on: @today - 1)
      else
        current.update!(ends_on: @today - 1)
      end
      profile = @company.client_operating_profiles.create!(
        **OperatingProfileCatalog.attributes_from(validated(current)),
        effective_on: @today,
        ends_on: ends_on,
        version: profiles.map(&:version).max + 1,
        # The newest version carries the editor's optimistic lock forward.
        lock_version: later.empty? ? current.lock_version : 0,
        changed_by: @actor,
        reason: @reason,
        confirmed_at: current.confirmed_at
      )
      audit!(profile, before, amended: false)
      profile
    end

    def amend!(profile)
      return nil unless changes?(profile)

      before = OperatingProfileCatalog.values_for(profile)
      profile.update!(**OperatingProfileCatalog.attributes_from(validated(profile)), changed_by: @actor, reason: @reason)
      audit!(profile, before, amended: true)
      profile
    end

    def changes?(profile)
      merged_values(profile) != OperatingProfileCatalog.values_for(profile)
    end

    def merged_values(profile)
      locked_defaults = CompanyFeatures::LOCKED_OFF.index_with { |key| OperatingProfileCatalog.locked_default_for(key) }
      OperatingProfileCatalog.values_for(profile).merge(@values).merge(locked_defaults)
    end

    def validated(profile)
      after = merged_values(profile)
      errors = OperatingProfileCatalog.change_errors(after)
      raise Invalid, errors.to_sentence if errors.present?

      after
    end

    def audit!(profile, before, amended:)
      after = OperatingProfileCatalog.values_for(profile)
      changed = after.keys.reject { |key| after.fetch(key) == before.fetch(key) }
      who = @actor ? { user: @actor } : { actor: AuditActor.system_job(self.class.name), user: nil }
      AuditLog.record!(
        **who, company_id: @company.id, organization_id: @company.organization_id,
        action: ClientOperatingProfiles::UpdateService::AUDIT_ACTION, record_type: profile.class.name, record_id: profile.id,
        subject_name: @company.name, event_category: "configuration",
        metadata: {
          version: profile.version, effective_on: profile.effective_on.iso8601, reason: @reason, amended: amended,
          source: "employee_app_switch", changed_fields: changed,
          before_values: before.slice(*changed), after_values: after.slice(*changed)
        }
      )
    end
  end
end
