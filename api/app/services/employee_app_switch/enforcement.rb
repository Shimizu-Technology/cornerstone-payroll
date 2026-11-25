# frozen_string_literal: true

module EmployeeAppSwitch
  # Whether the database really enforces company separation, and the demo
  # gate built on it (docs/DEMO_COMPANY_PLAN_2026-11-25.md §4).
  #
  # Enforcement counts only when every protected table has its policy,
  # row-level security is enabled and forced on all of them, AND the global
  # kill switch (rls_admin.rls_kill_switch) is not bypassing. Anything it
  # can't read is "unknown", which never counts.
  #
  # A demo company's employee app is open only while enforcement is
  # verified, or while an in-effect early-access window names that exact
  # company (Guam date). Expiry therefore takes effect on the next request;
  # DemoExpiry only reconciles the stored switches. Once enforcement is
  # verified, open windows are retired so a later return to shadow mode
  # doesn't revive them.
  module Enforcement
    CACHE_SECONDS = 5
    ROLE_CACHE_SECONDS = 30
    RETIRED_ACTION = "employee_app_early_access#retired"

    STATE_CACHE = Concurrent::AtomicReference.new
    ROLE_CACHE = Concurrent::AtomicReference.new

    module_function

    def reset_cache!
      STATE_CACHE.set(nil)
      ROLE_CACHE.set(nil)
    end

    # Read fresh on this process (the switch screen and readiness checks).
    def database_state
      rows, bypass = ActiveRecord::Base.connection_pool.with_connection do |connection|
        [ RlsDatabase.table_status(connection), kill_switch_bypass(connection) ]
      end
      total = RlsTables::PROTECTED_TABLES.size
      installed = rows.size == total && rows.all? { |row| row.fetch("policy") }
      enforced_count = rows.count { |row| row.fetch("enabled") && row.fetch("forced") }
      untouched = rows.none? { |row| row.fetch("enabled") || row.fetch("forced") }
      phase = if !installed then "not_installed"
      elsif bypass.nil? then "unknown"
      elsif bypass then "bypassed"
      elsif enforced_count == total then "enforced"
      elsif untouched then "shadow"
      else "partial"
      end
      { phase: phase, enforced: phase == "enforced", kill_switch_bypass: bypass,
        enforced_tables: enforced_count, protected_tables: total }
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch] database state unavailable: #{error.class}")
      { phase: "unknown", enforced: false, kill_switch_bypass: nil, enforced_tables: 0,
        protected_tables: RlsTables::PROTECTED_TABLES.size }
    end

    # true, false, or nil when the switch can't be read (not installed,
    # no row, no privilege).
    def kill_switch_bypass(connection)
      return nil unless connection.select_value("SELECT to_regclass('#{RlsDatabase::SWITCH}') IS NOT NULL") == true

      value = connection.select_value("SELECT bypass_enabled FROM #{RlsDatabase::SWITCH} WHERE singleton")
      [ true, false ].include?(value) ? value : nil
    rescue ActiveRecord::StatementInvalid
      nil
    end

    # The demo early-access waiver accepts only the intended shadow state:
    # policies installed, no table enforced yet, and the kill switch known
    # and not bypassing (a bypass also silences the employee guard).
    def shadow?(state)
      state[:phase] == "shadow" && state[:kill_switch_bypass] == false
    end

    # The database state, cached for a few seconds per process;
    # CompanyFeatures reads it on every demo company lookup.
    def cached_state
      cached = STATE_CACHE.get
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return cached.first if cached && now < cached.last

      state = database_state.slice(:phase, :enforced, :kill_switch_bypass).freeze
      STATE_CACHE.compare_and_set(cached, [ state, now + CACHE_SECONDS ].freeze)
      state
    end

    def verified?
      cached_state[:enforced] == true
    end

    # The early-access waiver applies only in the intended shadow state; a
    # partial, bypassed, not-installed or unreadable database never counts.
    def waiver_state?
      shadow?(cached_state)
    end

    # Read-time gate for a demo company's employee app: verified
    # enforcement, or the shadow state with an in-effect window naming the
    # company.
    def demo_open?(company, today: PayrollBusinessClock.today)
      if verified?
        retire_windows!
        return true
      end

      waiver_state? && EmployeeAppEarlyAccessWindow.current_for(company.organization_id)&.covers?(company, today: today) == true
    end

    # The full gate every reader uses (CompanyFeatures, so requests, jobs and
    # mail alike): the window rule above AND, under the waiver, this process
    # running the guard in raise mode as the restricted role with no bypass.
    # A job on an unguarded worker therefore sees the demo's app as off and
    # does nothing.
    def demo_app_open?(company, today: PayrollBusinessClock.today)
      return true unless company&.demo?

      demo_open?(company, today: today) && demo_request_allowed?(company)
    end

    # Once enforcement is verified, every open window retires for good.
    # retired_at is the durable record; the audit row is written where an
    # organization-wide row fits the scope (the sweep, a system request) and
    # logged otherwise. Never raises: a failed write is retried on the next
    # read or sweep.
    def retire_windows!(now: Time.current)
      windows = EmployeeAppEarlyAccessWindow.open.order(:id).to_a
      return 0 if windows.empty?

      count = EmployeeAppEarlyAccessWindow.where(id: windows.map(&:id)).open.update_all(retired_at: now, updated_at: now)
      Rails.logger.info("[EmployeeAppSwitch::Enforcement] retired early access windows=#{windows.map(&:id).join(',')}")
      windows.each { |window| audit_retired!(window) } if count.positive? && TenantScope.current&.mode != "company"
      count
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch::Enforcement] could not retire early access: #{error.class}")
      0
    end

    def audit_retired!(window)
      record = lambda do
        AuditLog.record!(
          actor: AuditActor.system_job(name), user: nil, organization_id: window.organization_id, company_id: nil,
          action: RETIRED_ACTION, record_type: "EmployeeAppEarlyAccessWindow", record_id: window.id,
          subject_name: EmployeeAppEarlyAccessWindow::NAME, event_category: "security",
          metadata: { reason: "The database enforces row-level security", company_ids: window.company_ids }
        )
      end
      TenantScope.current ? record.call : TenantScope.as_system(reason: "Retire demo early access", &record)
    end

    # Request-time check for a demo company's employee portal: under the
    # early-access waiver, THIS process must run the RLS guard in raise mode
    # as the restricted role, with the kill switch not bypassing.
    def demo_request_allowed?(company)
      return true unless company&.demo?
      return true if verified?

      waiver_state? && current_process_guarded?
    end

    def current_process_guarded?(env: ENV)
      return false unless RlsConfiguration.mode(env) == "raise" && RlsConfiguration.runtime_url(env)

      ActiveRecord::Base.connection_pool.with_connection do |connection|
        # An unreadable or missing kill switch row is unknown: closed.
        runtime_role_verified?(connection) && RlsDatabase.bypass_state(connection) == false
      end
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch::Enforcement] current process check failed: #{error.class}")
      false
    end

    def runtime_role_verified?(connection)
      cached = ROLE_CACHE.get
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return cached.first if cached && now < cached.last

      value = begin
        RlsDatabase.verify_runtime!(connection) == true
      rescue StandardError
        false
      end
      ROLE_CACHE.compare_and_set(cached, [ value, now + ROLE_CACHE_SECONDS ].freeze)
      value
    end
  end
end
