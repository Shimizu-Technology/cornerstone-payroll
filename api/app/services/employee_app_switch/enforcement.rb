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
    # How long this process trusts the employee service's signed answer that
    # its guard runs in raise mode, and how long a missing answer is reused
    # before asking again.
    ATTESTATION_CACHE_SECONDS = 120
    ATTESTATION_MISS_CACHE_SECONDS = 15
    # The ask is bounded tighter than the readiness screen's, since an
    # invitation or a job may be waiting on it.
    ATTESTATION_OPEN_TIMEOUT = 1
    ATTESTATION_READ_TIMEOUT = 2
    # The whole ask ends by then, however slowly a body trickles in.
    ATTESTATION_DEADLINE_SECONDS = 3
    # How long another caller waits for a refresh already under way before
    # treating the demo's app as off.
    ATTESTATION_WAIT_SECONDS = 0.5
    ATTESTATION_WAIT_STEP = 0.05
    CACHE_ONLY_KEY = :employee_app_switch_attestation_cache_only
    # Processes that may take the employee service's answer: never the
    # employee service itself.
    ATTESTATION_ROLES = [ ProcessRole::ALL, ProcessRole::PAYROLL_WEB ].freeze
    RETIRED_ACTION = "employee_app_early_access#retired"

    STATE_CACHE = Concurrent::AtomicReference.new
    ROLE_CACHE = Concurrent::AtomicReference.new
    ATTESTATION_CACHE = Concurrent::AtomicReference.new
    # One refresh at a time per process; the others wait briefly for it.
    ATTESTATION_LOCK = Mutex.new

    module_function

    def reset_cache!
      STATE_CACHE.set(nil)
      ROLE_CACHE.set(nil)
      ATTESTATION_CACHE.set(nil)
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
      RlsDatabase.kill_switch(connection)
    end

    # The demo early-access waiver accepts only the intended shadow state:
    # policies installed, no table enforced yet, and the kill switch known
    # and not bypassing (a bypass also silences the employee guard).
    def shadow?(state)
      state[:phase] == "shadow" && state[:kill_switch_bypass] == false
    end

    # The database state, cached for CACHE_SECONDS per process;
    # CompanyFeatures reads it on every demo company lookup.
    #
    # Intentional: a verified result can be reused for up to CACHE_SECONDS
    # after enforcement is turned off (RLS disabled on a table, or the kill
    # switch set to bypass), so a demo's employee app can stay open on this
    # process that long. A fresh read here would not close it any sooner:
    # the RLS guard reads the kill switch through the same 5-second cache
    # (RlsDatabase.bypass_state). The demo kill switch (DemoStop) and turning
    # a demo's app off take effect on the next request, uncached.
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
    def demo_open?(company, today: PayrollBusinessClock.today, retire_windows: true)
      if verified?
        retire_windows! if retire_windows
        return true
      end

      waiver_state? && EmployeeAppEarlyAccessWindow.current_for(company.organization_id)&.covers?(company, today: today) == true
    end

    # The full gate every reader uses (CompanyFeatures, so requests, jobs and
    # mail alike): the window rule above AND, under the waiver, the employee
    # service's guard in raise mode as the restricted role with no bypass
    # (demo_reader_allowed?). Without that, a job sees the demo's app as off
    # and does nothing.
    def demo_app_open?(company, today: PayrollBusinessClock.today, retire_windows: true)
      return true unless company&.demo?

      demo_open?(company, today: today, retire_windows: retire_windows) && demo_reader_allowed?(company)
    end

    # Company and support reads can open the demo as soon as enforcement is
    # verified. The system sweep can retire any windows those reads leave open.
    def retire_windows!(now: Time.current)
      return 0 if TenantScope.current&.mode == "company" || Current.view_as_grant

      actor = AuditActor.system_job(name)
      count = TenantScope.as_system(reason: "Retire verified demo early access and record organization audits") do
        Current.with_isolated_actor(actor) do
          EmployeeAppEarlyAccessWindow.open.distinct.order(:organization_id).pluck(:organization_id).sum do |organization_id|
            retire_organization_window!(organization_id, now: now, actor: actor)
          end
        end
      end
      Rails.logger.info("[EmployeeAppSwitch::Enforcement] retired early access windows=#{count}") if count.positive?
      count
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch::Enforcement] could not retire early access: #{error.class}")
      0
    end

    def retire_organization_window!(organization_id, now:, actor:)
      EmployeeAppEarlyAccessWindow.transaction(requires_new: true) do
        # Set, end, and emergency stop lock the organization before the window.
        next 0 unless Organization.where(id: organization_id).lock("FOR KEY SHARE SKIP LOCKED").pick(:id)

        window = EmployeeAppEarlyAccessWindow.open.lock("FOR UPDATE SKIP LOCKED").find_by(organization_id: organization_id)
        next 0 unless window

        window.update!(retired_at: now, updated_at: now)
        audit_retired!(window, actor: actor)
        1
      end
    rescue StandardError => error
      Rails.logger.warn("[EmployeeAppSwitch::Enforcement] could not retire early access: #{error.class}")
      0
    end
    private_class_method :retire_organization_window!

    def audit_retired!(window, actor:)
      AuditLog.record!(
        actor: actor, user: nil, organization_id: window.organization_id, company_id: nil,
        action: RETIRED_ACTION, record_type: "EmployeeAppEarlyAccessWindow", record_id: window.id,
        subject_name: EmployeeAppEarlyAccessWindow::NAME, event_category: "security",
        metadata: { reason: "The database enforces row-level security", company_ids: window.company_ids }
      )
    end

    # Request-time check for a demo company's employee portal: under the
    # early-access waiver, THIS process must run the RLS guard in raise mode
    # as the restricted role, with the kill switch not bypassing.
    def demo_request_allowed?(company)
      return true unless company&.demo?
      return true if verified?

      waiver_state? && current_process_guarded?
    end

    # Whether a demo link's sign-up or claim may even be checked on this
    # process: only a process running its own guard (the employee service)
    # serves one, in the early-access and the verified state alike.
    # Elsewhere Activate and Claim refuse it before Verify locks or counts
    # anything, so a match and a miss get the same answer. Callers ask this
    # first: the process check reads no cached database state, and a later
    # check (a subdomain or app-open read) could ask the employee service or
    # retire early-access windows.
    def demo_sign_up_admitted?(company)
      return true unless company&.demo?

      current_process_guarded? && demo_request_allowed?(company)
    end

    # Whether a demo's app reads as on under the waiver. The employee service
    # needs its own guard, exactly as demo_request_allowed?. Staff web and
    # the worker serve no employee data on this answer, so they follow the
    # employee service's signed answer that its guard runs in raise mode as
    # the restricted role (ServiceAttestation). That path is opt-in: only an
    # `all` or `payroll_web` process with EMPLOYEE_API_URL set takes it.
    # Employee requests on any process still pass demo_request_allowed?.
    def demo_reader_allowed?(company, env: ENV)
      return true unless company&.demo?
      return true if verified?
      return false unless waiver_state?
      return true if current_process_guarded?(env: env)
      return false unless remote_attestation_allowed?(env)

      employee_service_attested?(env: env)
    end

    def remote_attestation_allowed?(env = ENV)
      ATTESTATION_ROLES.include?(env["APP_PROCESS_ROLE"].presence || ProcessRole::ALL) && env["EMPLOYEE_API_URL"].present?
    end

    # Asks for the employee service's answer ahead of a locked section (an
    # invitation), so the re-check inside it reads the cache.
    def warm_attestation!(company)
      demo_app_open?(company) if company&.demo?
      nil
    end

    # Until the current transaction ends, this thread reads only the cached
    # answer and never asks the employee service: an invitation holding the
    # company's issuance lock must not wait on the network while DemoStop
    # waits on that lock. An expired answer then reads as off.
    def cached_attestation_only!
      ActiveSupport::IsolatedExecutionState[CACHE_ONLY_KEY] = ActiveRecord::Base.current_transaction
    end

    def cached_attestation_only?
      ActiveSupport::IsolatedExecutionState[CACHE_ONLY_KEY]&.open? == true
    end

    # The employee service's live signed answer (checked for this nonce,
    # process and age), cached per process. Anything else (no secret or URL,
    # unsigned, stale, unreachable, a guard not in raise mode) is false, and
    # an expired answer is never served. One thread refreshes; another waits
    # up to ATTESTATION_WAIT_SECONDS for it, then reads the app as off.
    def employee_service_attested?(env: ENV)
      cached = fresh_attestation
      return cached.first if cached
      return false if cached_attestation_only?

      give_up_at = monotonic_now + ATTESTATION_WAIT_SECONDS
      until ATTESTATION_LOCK.try_lock
        return false if monotonic_now >= give_up_at

        sleep(ATTESTATION_WAIT_STEP)
        cached = fresh_attestation
        return cached.first if cached
      end
      begin
        cached = fresh_attestation
        return cached.first if cached

        value = fetch_attestation(env)
        ttl = value ? ATTESTATION_CACHE_SECONDS : ATTESTATION_MISS_CACHE_SECONDS
        ATTESTATION_CACHE.set([ value, monotonic_now + ttl ].freeze)
        value
      ensure
        ATTESTATION_LOCK.unlock
      end
    end

    def fresh_attestation
      cached = ATTESTATION_CACHE.get
      cached if cached && monotonic_now < cached.last
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Only the network ask runs under the deadline; nothing here touches the
    # database.
    def fetch_attestation(env)
      ping = Timeout.timeout(ATTESTATION_DEADLINE_SECONDS) do
        Readiness.ping_employee_service(env, open_timeout: ATTESTATION_OPEN_TIMEOUT, read_timeout: ATTESTATION_READ_TIMEOUT)
      end
      ping[:observation]&.rls_guard_raise? == true
    rescue StandardError => error # Timeout::Error included
      Rails.logger.warn("[EmployeeAppSwitch::Enforcement] employee service attestation failed: #{error.class}")
      false
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
