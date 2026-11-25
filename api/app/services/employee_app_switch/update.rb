# frozen_string_literal: true

module EmployeeAppSwitch
  # Turns parts of one company's employee app on or off, with a reason, and
  # audits the change with the readiness result it was checked against.
  # Turning on requires every applicable check and records an activation
  # (EmployeeAppActivation) with the checks it passed; turning off always
  # works, revokes the activation and clears today's and every later
  # scheduled version. Turning the employee app off also turns off every
  # feature under it.
  #
  # The service itself requires what turning on needs, so no caller can skip
  # it: the actor's verified session claims (session_claims:, the Clerk
  # token payload) must show a second factor verified within the step-up
  # window, and the readiness checks are always built here, never passed in.
  class Update
    attr_reader :company, :actor

    def initialize(company:, actor:, changes:, reason:, session_claims:, today: PayrollBusinessClock.today)
      @company = company
      @actor = actor
      @raw_changes = changes
      @raw_reason = reason
      @session_claims = session_claims
      @today = today
    end

    def changes
      @changes ||= parse_changes
    end

    def turning_on?
      changes.value?(true)
    end

    def readiness
      @readiness ||= Readiness.new(company: company, today: @today)
    end

    # Raises NotReady before anything is locked or written, so the screen can
    # list the failing checks without asking for a fresh second factor first.
    def preflight!
      reason = EmployeeAppSwitch.reason!(@raw_reason)
      authorize!(actor)
      plan(*state)
      reason
    end

    def call
      reason = EmployeeAppSwitch.reason!(@raw_reason)
      require_step_up! if turning_on?
      company.with_lock(requires_new: true) do
        fresh_actor = User.lock.find_by(id: actor&.id)
        company.company_assignments.where(user_id: fresh_actor&.id).lock.load
        authorize!(fresh_actor)

        after, turned_on, turned_off = plan(*state)
        ProfileWriter.apply!(company: company, actor: fresh_actor, values: after.slice(*(turned_on + turned_off)),
          reason: "Employee app switch: #{reason}", today: @today)
        window = early_access_window(turned_on)
        turned_on.each do |key|
          EmployeeAppActivation.activate!(company: company, part: key, actor: fresh_actor, early_access_window: window,
            checks: readiness.checks_for(key).map { |check| check.as_json.slice(:key, :status) })
        end
        audit!(fresh_actor, reason, turned_on, turned_off, window)
        { turned_on: turned_on, turned_off: turned_off, values: after }
      end
    end

    private

    def parse_changes
      raise Invalid, "Choose at least one switch to change." unless @raw_changes.is_a?(Hash) && @raw_changes.present?

      @raw_changes.to_h.stringify_keys.to_h do |key, value|
        if STAYS_OFF.key?(key)
          raise Invalid, "#{STAYS_OFF.dig(key, :label)} #{STAYS_OFF.dig(key, :description).sub(/\AStays/, 'stays')}"
        end
        raise Invalid, "Unknown employee app switch: #{key}" unless SWITCHES.key?(key)
        raise Invalid, "#{EmployeeAppSwitch.label(key)} must be turned on or off." unless [ true, false ].include?(value)

        [ key, value ]
      end
    end

    def require_step_up!
      raise StepUpRequired unless MfaPolicy.recently_verified_second_factor?(@session_claims)
    end

    def authorize!(user)
      unless EmployeeAppSwitch.allowed?(user, company)
        raise Forbidden, "Only organization admins can change the employee app switch."
      end
    end

    # before: what's on today (stored and activated). on_anywhere: parts with
    # anything left to turn off, today or in a later scheduled version.
    def state
      [ EmployeeAppSwitch.switched_on_values(company, today: @today), EmployeeAppSwitch.on_anywhere(company, today: @today) ]
    end

    def plan(before, on_anywhere)
      after = before.merge(changes)
      if changes.any? { |key, value| value && FEATURES.include?(key) } && !after.fetch(MASTER)
        raise Invalid, "Turn on the employee app before turning on its features."
      end
      off = changes.select { |_key, value| value == false }.keys
      unless after.fetch(MASTER)
        after = after.merge(FEATURES.index_with(false))
        off |= FEATURES
      end
      turned_on = KEYS.select { |key| after[key] && !before[key] }
      turned_off = KEYS.select { |key| off.include?(key) && on_anywhere.include?(key) }
      raise Invalid, "Nothing to change: those switches are already set that way." if turned_on.empty? && turned_off.empty?

      if turned_on.any?
        failures = turned_on.flat_map { |key| readiness.failures_for(key) }.uniq(&:key)
        raise NotReady, failures if failures.any?
      end
      [ after, turned_on, turned_off ]
    end

    def early_access_window(turned_on)
      turned_on.any? && readiness.exception_applied? ? EmployeeAppEarlyAccessWindow.current_for(company.organization_id) : nil
    end

    def audit!(user, reason, turned_on, turned_off, window)
      checks = turned_on.any? ? turned_on.flat_map { |key| readiness.checks_for(key) }.uniq(&:key) : []
      AuditLog.record!(
        user: user, company_id: company.id, organization_id: company.organization_id,
        action: AUDIT_ACTION, record_type: "Company", record_id: company.id, subject_name: company.name,
        event_category: "security",
        metadata: {
          reason: reason, turned_on: turned_on, turned_off: turned_off,
          readiness: checks.map { |check| check.as_json.slice(:key, :status) },
          early_access_window_id: window&.id
        }.compact
      )
    end
  end
end
