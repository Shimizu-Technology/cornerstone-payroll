# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Lifecycle PR 3 lock-order and deadlock regression", :postgres_concurrency do
  self.use_transactional_tests = false

  include ActiveSupport::Testing::TimeHelpers

  def create_ready_w4!(employee, effective_on: Date.new(2026, 1, 1))
    EmployeeW4Election.create!(
      EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
        company: employee.company,
        employee: employee,
        effective_on: effective_on,
        w4_signed_on: effective_on,
        w4_form_version: 2020,
        source: "client_direct",
        reason: "Concurrency test W-4"
      )
    )
  end

  def with_worker_db_timeouts(conn, statement_ms: 10_000, lock_ms: 10_000)
    conn.execute("SET statement_timeout = #{Integer(statement_ms)}")
    conn.execute("SET lock_timeout = #{Integer(lock_ms)}")
    yield
  ensure
    conn.execute("RESET statement_timeout") rescue nil
    conn.execute("RESET lock_timeout") rescue nil
  end

  def stop_and_join_workers!(threads, barriers: [], release_queues: [], join_timeout: 5, kill_timeout: 5)
    worker_threads = Array(threads).compact
    Array(barriers).compact.each { |q| worker_threads.size.times { q << true } }
    Array(release_queues).compact.each { |q| q << true }
    worker_threads.each do |thread|
      next unless thread.alive?
      next if thread.join(join_timeout)

      thread.kill
      thread.join(kill_timeout)
    end

    still_alive = worker_threads.select(&:alive?)
    return if still_alive.empty?

    raise "Refusing to clean up non-transactional fixtures while #{still_alive.size} worker thread(s) remain alive"
  end

  def cleanup_non_transactional_company!(company:, organization:, user_ids:, tax_tables:)
    if company&.persisted?
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn.transaction(requires_new: true) do
          conn.execute("ALTER TABLE pay_period_verification_acknowledgements DISABLE TRIGGER pay_period_verification_acknowledgements_append_only")
          PayPeriodVerificationAcknowledgement.where(company_id: company.id).delete_all
          conn.execute("ALTER TABLE pay_period_verification_acknowledgements ENABLE TRIGGER pay_period_verification_acknowledgements_append_only")
        end
        conn.transaction(requires_new: true) do
          conn.execute("ALTER TABLE check_events DISABLE TRIGGER check_events_append_only")
          CheckEvent.where(company_id: company.id).delete_all
          conn.execute("ALTER TABLE check_events ENABLE TRIGGER check_events_append_only")
        end

        event_ids = PortalNotificationEvent.where(company_id: company.id).pluck(:id)
        PortalNotificationDelivery.where(portal_notification_event_id: event_ids).delete_all if event_ids.any?
        PortalNotificationEvent.where(id: event_ids).delete_all if event_ids.any?
        EmployeeVerificationItem.where(company_id: company.id).update_all(superseded_by_id: nil)
        EmployeeVerificationItem.where(company_id: company.id).delete_all
        EmployeeChangeRequest.where(company_id: company.id).delete_all
        EmployeeDocumentRequirement.where(company_id: company.id).delete_all if defined?(EmployeeDocumentRequirement)
        NonEmployeeCheck.where(company_id: company.id).find_each(&:destroy!)
        PayrollLiabilityEntry.where(company_id: company.id).delete_all if defined?(PayrollLiabilityEntry)
        PayrollLiabilityPosting.where(company_id: company.id).delete_all if defined?(PayrollLiabilityPosting)
        PayrollReviewPackage.where(company_id: company.id).delete_all if defined?(PayrollReviewPackage)
        item_ids = PayrollItem.where(company_id: company.id).pluck(:id)
        PayrollItemEarning.where(payroll_item_id: item_ids).delete_all if item_ids.any?
        PayrollItemDeduction.where(payroll_item_id: item_ids).delete_all if item_ids.any?
        PayrollItem.where(id: item_ids).delete_all if item_ids.any?
        employee_ids = Employee.where(company_id: company.id).pluck(:id)
        EmployeeYtdTotal.where(employee_id: employee_ids).delete_all if employee_ids.any?
        CompanyYtdTotal.where(company_id: company.id).delete_all
        EmployeeStatusEvent.where(company_id: company.id).delete_all
        EmployeeW4Election.where(company_id: company.id).delete_all
        EmployeeCompensationChange.where(company_id: company.id).delete_all
        PayPeriod.where(company_id: company.id).delete_all
        Employee.where(company_id: company.id).delete_all
        Department.where(company_id: company.id).delete_all
        PortalNotificationRecipient.where(company_id: company.id).delete_all
        ClientOperatingProfile.where(company_id: company.id).delete_all
        CompanyAssignment.where(company_id: company.id).delete_all
        AuditLog.where(company_id: company.id).delete_all
        User.where(id: Array(user_ids).compact).delete_all if Array(user_ids).compact.any?
        Company.where(id: company.id).delete_all
      end
    end
    if organization&.persisted?
      ActiveRecord::Base.connection_pool.with_connection do
        Organization.where(id: organization.id).delete_all
      end
    end
    Array(tax_tables).each(&:destroy!)
  end

  it "serializes parallel EmployeeStatusTransitionService (staff & client), PayPeriodLifecycleService#approve!/#commit!, and EmployeePaymentDefaultService without deadlocks" do
    threads = []
    round2_threads = []
    barrier = Queue.new
    barrier2 = Queue.new

    tax_tables = ensure_verified_test_tax_years(2026)
    organization = Organization.create!(name: "Lock Order Org #{SecureRandom.hex(4)}")
    company = create(:company, organization: organization, name: "Harborview Lock Bistro #{SecureRandom.hex(4)}")
    department = Department.create!(company: company, name: "Operations")
    staff_admin = create(:user, company: company, organization: organization, role: "admin", name: "Dana Staff")
    client_manager = create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner")
    CompanyAssignment.create!(user: staff_admin, company: company)
    CompanyAssignment.create!(user: client_manager, company: company)

    # Unlock lifecycle mode in memory for this concurrency test.
    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: Time.current
      )
    )

    employee = create(
      :employee,
      :hourly,
      company: company,
      department: department,
      first_name: "Jordan",
      last_name: "Sample",
      date_of_birth: Date.new(1994, 4, 12),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 22.00,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true
    )
    create_ready_w4!(employee)

    period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14),
      pay_date: Date.new(2026, 11, 20),
      status: "draft"
    )
    item = period.payroll_items.create!(
      company: company,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 22.00,
      hours_worked: 40,
      payment_delivery_method: "paper_check"
    )
    item.calculate!
    period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: staff_admin.id)

    # Round 1: Parallel approve! + ClientEmployeeUpdateService (payment_delivery_method + pay_rate) + payment default + staff deactivate! + client terminate!
    outcomes = Queue.new
    thread_count = 5

    threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier.pop
            PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period.id), actor: User.find(staff_admin.id)).approve!
            outcomes << [ :approve, :ok ]
          end
        rescue PayPeriodLifecycleService::Error => e
          outcomes << [ :approve, :domain_error, e.message ]
        rescue StandardError => e
          outcomes << [ :approve, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier.pop
            ClientEmployeeUpdateService.new(
              employee: Employee.find(employee.id),
              attrs: { payment_delivery_method: "direct_deposit", pay_rate: 23.50 },
              requested_by: User.find(client_manager.id),
              company: Company.find(company.id)
            ).update!
            outcomes << [ :client_update, :ok ]
          end
        rescue ActiveRecord::RecordInvalid => e
          outcomes << [ :client_update, :domain_error, e.record.errors.full_messages.join(", ") ]
        rescue StandardError => e
          outcomes << [ :client_update, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier.pop
            EmployeePaymentDefaultService.new(
              employee: Employee.find(employee.id),
              method: "direct_deposit",
              actor: User.find(staff_admin.id)
            ).call
            outcomes << [ :payment_default, :ok ]
          end
        rescue StandardError => e
          outcomes << [ :payment_default, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier.pop
            EmployeeStatusTransitionService.deactivate!(
              employee: Employee.find(employee.id),
              actor: User.find(staff_admin.id),
              attributes: { effective_date: "2026-11-10", reason_category: "seasonal" }
            )
            outcomes << [ :staff_deactivate, :ok ]
          end
        rescue EmployeeStatusTransitionService::Error => e
          outcomes << [ :staff_deactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes << [ :staff_deactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier.pop
            EmployeeStatusTransitionService.terminate!(
              employee: Employee.find(employee.id),
              actor: User.find(client_manager.id),
              attributes: { effective_date: "2026-11-10", reason_category: "voluntary", source: "client_portal" }
            )
            outcomes << [ :client_terminate, :ok ]
          end
        rescue EmployeeStatusTransitionService::Error => e
          outcomes << [ :client_terminate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes << [ :client_terminate, :unexpected, e.class.name, e.message ]
        end
      end
    ]

    thread_count.times { barrier << true }
    threads.each { |thread| Timeout.timeout(15) { thread.join } }

    round1 = thread_count.times.map { outcomes.pop }
    unexpected_round1 = round1.select { |entry| entry[1] == :unexpected }
    expect(unexpected_round1).to be_empty, "Expected zero deadlocks/unexpected errors in round 1, got: #{round1.inspect}"
    expected_round1_errors = /recalculat|stale|already terminated|Only active workers|approved pay run|status|changed after calculation|payment/i
    round1.select { |entry| entry[1] == :domain_error }.each do |entry|
      expect(entry[2]).to match(expected_round1_errors), "Unexpected domain error in round 1: #{entry.inspect}"
    end

    # Round 2: Parallel reactivate! (staff/client) + commit! + verification item write under Company.lock
    period.reload
    employee.reload
    if employee.status == "active"
      EmployeeStatusTransitionService.terminate!(
        employee: employee,
        actor: staff_admin,
        attributes: { effective_date: "2026-11-10", reason_category: "voluntary" }
      )
      employee.reload
    end

    period2 = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 11, 15),
      end_date: Date.new(2026, 11, 28),
      pay_date: Date.new(2026, 12, 4),
      status: "draft"
    )
    active_worker = create(
      :employee,
      :hourly,
      company: company,
      department: department,
      first_name: "Quinn",
      last_name: "Example",
      date_of_birth: Date.new(1992, 8, 5),
      hire_date: Date.new(2026, 1, 1),
      pay_rate: 25.00,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true
    )
    create_ready_w4!(active_worker)
    item2 = period2.payroll_items.create!(
      company: company,
      employee: active_worker,
      employment_type: "hourly",
      pay_rate: 25.00,
      hours_worked: 40,
      payment_delivery_method: "paper_check"
    )
    item2.calculate!
    period2.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: staff_admin.id)
    PayPeriodLifecycleService.new(pay_period: period2, actor: staff_admin).approve!

    verification_item = EmployeeVerificationItems::Recorder.record!(
      employee: active_worker,
      actor: client_manager,
      event_kind: "compensation_change",
      changed_fields: [ "pay_rate" ],
      before_values: { "pay_rate" => 24.0 },
      after_values: { "pay_rate" => 25.0 },
      effective_on: period2.start_date
    )
    ack_payload = [ { id: verification_item.id, updated_at: verification_item.updated_at.utc.iso8601(6) } ]

    outcomes2 = Queue.new
    round2_threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier2.pop
            PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period2.id), actor: User.find(staff_admin.id))
              .commit!(acknowledged_verification_items: ack_payload)
            outcomes2 << [ :commit, :ok ]
          end
        rescue PayPeriodLifecycleService::Error => e
          outcomes2 << [ :commit, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :commit, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier2.pop
            EmployeeStatusTransitionService.reactivate!(
              employee: Employee.find(employee.id),
              actor: User.find(staff_admin.id),
              attributes: { effective_date: "2026-11-15" }
            )
            outcomes2 << [ :staff_reactivate, :ok ]
          end
        rescue EmployeeStatusTransitionService::Error => e
          outcomes2 << [ :staff_reactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :staff_reactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier2.pop
            EmployeeStatusTransitionService.reactivate!(
              employee: Employee.find(employee.id),
              actor: User.find(client_manager.id),
              attributes: { effective_date: "2026-11-15", source: "client_portal" }
            )
            outcomes2 << [ :client_reactivate, :ok ]
          end
        rescue EmployeeStatusTransitionService::Error => e
          outcomes2 << [ :client_reactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :client_reactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier2.pop
            ClientEmployeeUpdateService.new(
              employee: Employee.find(active_worker.id),
              attrs: { payment_delivery_method: "direct_deposit", pay_rate: 26.50, compensation_effective_on: (period2.end_date + 1).iso8601 },
              requested_by: User.find(client_manager.id),
              company: Company.find(company.id)
            ).update!
            outcomes2 << [ :client_update, :ok ]
          end
        rescue ActiveRecord::RecordInvalid => e
          outcomes2 << [ :client_update, :domain_error, e.record.errors.full_messages.join(", ") ]
        rescue StandardError => e
          outcomes2 << [ :client_update, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            barrier2.pop
            EmployeeVerificationItems::Recorder.record!(
              employee: Employee.find(active_worker.id),
              actor: User.find(client_manager.id),
              event_kind: "compensation_change",
              changed_fields: [ "pay_rate" ],
              before_values: { "pay_rate" => 25.0 },
              after_values: { "pay_rate" => 26.0 },
              effective_on: period2.end_date + 1
            )
            outcomes2 << [ :verification_write, :ok ]
          end
        rescue StandardError => e
          outcomes2 << [ :verification_write, :unexpected, e.class.name, e.message ]
        end
      end
    ]

    round2_threads.size.times { barrier2 << true }
    round2_threads.each { |thread| Timeout.timeout(15) { thread.join } }

    round2 = round2_threads.size.times.map { outcomes2.pop }
    unexpected_round2 = round2.select { |entry| entry[1] == :unexpected }
    expect(unexpected_round2).to be_empty, "Expected zero deadlocks/unexpected errors in round 2, got: #{round2.inspect}"
    expected_round2_errors = /unverified|acknowledged|Only terminated|Only inactive|after the worker's latest status change|stale|recalculat|approved pay run/i
    round2.select { |entry| entry[1] == :domain_error }.each do |entry|
      expect(entry[2]).to match(expected_round2_errors), "Unexpected domain error in round 2: #{entry.inspect}"
    end

    # Exactly one reactivate succeeded; never a deadlock or duplicate reactivate event.
    reactivate_oks = round2.count { |entry| entry[0].to_s.include?("reactivate") && entry[1] == :ok }
    expect(reactivate_oks).to eq(1)

    # If commit succeeded, its acknowledged verification item must never have been superseded.
    if round2.any? { |entry| entry == [ :commit, :ok ] }
      expect(verification_item.reload.status).to eq("pending_verification")
      expect(verification_item.acknowledged_in_committed_run?).to be(true)
    end
  ensure
    stop_and_join_workers!(Array(threads) + Array(round2_threads), barriers: [ barrier, barrier2 ])
    cleanup_non_transactional_company!(
      company: company,
      organization: organization,
      user_ids: [ staff_admin&.id, client_manager&.id ],
      tax_tables: tax_tables
    )
  end

  it "deterministically blocks every writer on Company.lock before any Employee or PayPeriod lock is acquired (M4)" do
    barrier_threads = []
    barrier_releases = []

    organization = Organization.create!(name: "Barrier Lock Org #{SecureRandom.hex(4)}")
    company = create(:company, organization: organization, name: "Harborview Barrier #{SecureRandom.hex(4)}")
    department = Department.create!(company: company, name: "Operations")
    staff_admin = create(:user, company: company, organization: organization, role: "admin", name: "Dana Staff")
    client_manager = create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner")
    CompanyAssignment.create!(user: staff_admin, company: company)
    CompanyAssignment.create!(user: client_manager, company: company)

    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: Time.current
      )
    )

    employee = create(:employee, :hourly, company: company, department: department, first_name: "Jordan", last_name: "Barrier", hire_date: Date.new(2026, 1, 1), pay_rate: 20.0, payment_delivery_method: "paper_check")
    create_ready_w4!(employee)
    EmployeeVerificationItem.create!(
      company: company,
      employee: employee,
      event_kind: "compensation_change",
      status: "returned_to_client",
      affects_pay: true,
      changed_fields: [ "pay_rate" ],
      return_note: "Barrier requeue check"
    )

    writers = {
      client_update: -> {
        ClientEmployeeUpdateService.new(
          employee: Employee.find(employee.id),
          attrs: { payment_delivery_method: "direct_deposit", pay_rate: 21.50 },
          requested_by: User.find(client_manager.id),
          company: Company.find(company.id)
        ).update!
      },
      verification_record: -> {
        EmployeeVerificationItems::Recorder.record!(
          employee: Employee.find(employee.id),
          actor: User.find(client_manager.id),
          event_kind: "compensation_change",
          changed_fields: [ "pay_rate" ],
          before_values: { "pay_rate" => 21.50 },
          after_values: { "pay_rate" => 22.00 }
        )
      },
      requeue_returned: -> {
        EmployeeVerificationItems::Recorder.requeue_returned_items!(
          employee: Employee.find(employee.id),
          actor: User.find(client_manager.id),
          touched_fields: [ :pay_rate ]
        )
      },
      terminate: -> {
        EmployeeStatusTransitionService.terminate!(
          employee: Employee.find(employee.id),
          actor: User.find(client_manager.id),
          attributes: { effective_date: "2026-11-10", reason_category: "voluntary", source: "client_portal" }
        )
      }
    }

    writers.each do |label, action|
      holder_pid_q = Queue.new
      waiter_pid_q = Queue.new
      release_holder = Queue.new
      barrier_releases << release_holder
      waiter_error = nil

      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            ActiveRecord::Base.transaction do
              Company.lock.find(company.id)
              holder_pid_q << conn.select_value("SELECT pg_backend_pid()").to_i
              Timeout.timeout(10) { release_holder.pop }
            end
          end
        end
      end
      barrier_threads << holder

      holder_pid = Timeout.timeout(5) { holder_pid_q.pop }

      waiter = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          with_worker_db_timeouts(conn) do
            waiter_pid_q << conn.select_value("SELECT pg_backend_pid()").to_i
            action.call
          end
        rescue StandardError => e
          waiter_error = e
        end
      end
      barrier_threads << waiter

      waiter_pid = Timeout.timeout(5) { waiter_pid_q.pop }

      blocked_by_holder = false
      waiting_on_company_lock = false
      held_row_locks = []
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          blocking = conn.select_values("SELECT unnest(pg_blocking_pids(#{waiter_pid}))").map(&:to_i)
          if blocking.include?(holder_pid)
            blocked_by_holder = true
            waiting_on_company_lock = conn.select_value(<<~SQL.squish).to_i.positive?
              SELECT COUNT(*)
              FROM pg_locks l
              JOIN pg_class c ON c.oid = l.relation
              WHERE l.pid = #{waiter_pid}
                AND c.relname = 'companies'
                AND l.mode IN ('RowShareLock', 'RowExclusiveLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
            SQL
            held_row_locks = conn.select_values(<<~SQL.squish)
              SELECT c.relname
              FROM pg_locks l
              JOIN pg_class c ON c.oid = l.relation
              WHERE l.pid = #{waiter_pid}
                AND l.granted = TRUE
                AND l.locktype IN ('relation', 'tuple')
                AND l.mode IN ('RowShareLock', 'RowExclusiveLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
                AND c.relname IN ('employees', 'pay_periods')
            SQL
            break
          end
          sleep 0.01
        end
      end

      release_holder << true
      Timeout.timeout(10) { holder.join }
      Timeout.timeout(10) { waiter.join }

      expect(blocked_by_holder).to be(true), "Expected #{label} to block on Company.lock held by Thread A (preventing Employee->PayPeriod inversion)"
      expect(waiting_on_company_lock).to be(true), "Expected #{label} to be waiting on companies lock held by Thread A"
      expect(held_row_locks).to be_empty, "Expected #{label} to hold zero Employee/PayPeriod SELECT FOR UPDATE or write locks while waiting on Company.lock, got: #{held_row_locks.inspect}"
      expect(waiter_error).to be_nil, "Expected #{label} to serialize cleanly after Company.lock released, got: #{waiter_error.inspect}"
    end
  ensure
    stop_and_join_workers!(barrier_threads, release_queues: barrier_releases)
    cleanup_non_transactional_company!(
      company: company,
      organization: organization,
      user_ids: [ staff_admin&.id, client_manager&.id ],
      tax_tables: []
    )
  end

  it "commits on-demand lifecycle activation outside the caller write transaction and refuses mid-request mode flips (M5)" do
    organization = Organization.create!(name: "Activation Tx Org #{SecureRandom.hex(4)}")
    company = create(:company, organization: organization, name: "Harborview Tx #{SecureRandom.hex(4)}")
    department = Department.create!(company: company, name: "Operations")
    org_admin = create(:user, company: company, organization: organization, role: "org_admin", name: "Alex Admin")
    staff_manager = create(:user, company: company, organization: organization, role: "manager", name: "Dana Manager")
    client_manager = create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner")
    CompanyAssignment.create!(user: org_admin, company: company)
    CompanyAssignment.create!(user: staff_manager, company: company)
    CompanyAssignment.create!(user: client_manager, company: company)

    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
    PortalNotificationRecipient.create!(company: company, user: staff_manager, team_role: "lead", added_by: org_admin)

    # Case 1: Blocked due scheduled profile survives a failing client write transaction rollback!
    worker = create(:employee, :hourly, company: company, department: department, first_name: "Casey", last_name: "Blocker")
    blocker_req = create(
      :employee_change_request,
      company: company,
      employee: worker,
      requested_by: client_manager,
      proposed_changes: { pay_rate: 29.0 },
      original_values: { pay_rate: 20.0 }
    )
    due_profile = ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: nil
      )
    )

    # N5: default attempt_lifecycle_activation is false (opt-in), and opt-in refuses to run inside an open transaction
    expect do
      ActiveRecord::Base.transaction do
        ClientEmployeeUpdateService.new(
          employee: Employee.new,
          attrs: { first_name: "InsideTx", last_name: "Refused", employment_type: "hourly" },
          requested_by: client_manager,
          company: company,
          attempt_lifecycle_activation: true
        ).create!
      end
    end.to raise_error(ArgumentError, /open database transaction/)
    expect(due_profile.reload.lifecycle_mode_activation_failed_at).to be_nil

    # Failing create (missing required last_name -> ActiveRecord::RecordInvalid rolls back write tx)
    expect do
      ClientEmployeeUpdateService.new(
        employee: Employee.new,
        attrs: { first_name: "InvalidOnly", employment_type: "hourly" },
        requested_by: client_manager,
        company: company,
        attempt_lifecycle_activation: true
      ).create!
    end.to raise_error(ActiveRecord::RecordInvalid)

    # Blocked stamp and audit row MUST survive the rolled-back write transaction!
    expect(due_profile.reload.lifecycle_mode_activation_failed_at).to be_present
    expect(due_profile.lifecycle_mode_activation_blockers).to include("pending_non_address_change_requests_count" => 1)
    blocked_audits_after_first = AuditLog.where(company_id: company.id, action: "client_operating_profile.lifecycle_mode_activation_blocked").count
    expect(blocked_audits_after_first).to eq(1)

    # Second failing write must NOT re-attempt or duplicate the blocked audit row
    expect do
      ClientEmployeeUpdateService.new(
        employee: Employee.new,
        attrs: { first_name: "InvalidAgain", employment_type: "hourly" },
        requested_by: client_manager,
        company: company,
        attempt_lifecycle_activation: true
      ).create!
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(AuditLog.where(company_id: company.id, action: "client_operating_profile.lifecycle_mode_activation_blocked").count).to eq(1)

    # Case 2: Successful activation commits independently and raises ModeChanged so the in-flight request never flips mode mid-request!
    blocker_req.update!(status: :rejected, reviewed_by: staff_manager, reviewed_at: Time.current, review_notes: "Resolved")
    due_profile.update!(lifecycle_mode_activation_failed_at: nil, lifecycle_mode_activation_blockers: {})

    expect do
      ClientEmployeeUpdateService.new(
        employee: Employee.new,
        attrs: { first_name: "MidRequest", last_name: "Flip", employment_type: "hourly" },
        requested_by: client_manager,
        company: company,
        attempt_lifecycle_activation: true
      ).create!
    end.to raise_error(ClientOperatingProfiles::LifecycleModeActivationService::ModeChanged)
      .and change(Employee, :count).by(0)

    # Activation IS committed in DB, so the immediate retry runs cleanly in client_managed mode!
    expect(due_profile.reload.lifecycle_mode_activated_at).to be_present
    retry_result = ClientEmployeeUpdateService.new(
      employee: Employee.new,
      attrs: { first_name: "AfterReload", last_name: "Hire", employment_type: "hourly" },
      requested_by: client_manager,
      company: company,
      attempt_lifecycle_activation: true
    ).create!
    expect(retry_result.client_managed).to be(true)
    expect(retry_result.employee.readiness_gate_enforced).to be(true)
  ensure
    cleanup_non_transactional_company!(
      company: company,
      organization: organization,
      user_ids: [ org_admin&.id, staff_manager&.id, client_manager&.id ],
      tax_tables: []
    )
  end
end
