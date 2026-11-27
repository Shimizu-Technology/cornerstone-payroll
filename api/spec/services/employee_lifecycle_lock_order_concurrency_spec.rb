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

    # Round 1: Parallel approve! + payment default change + staff deactivate! + client terminate!
    barrier = Queue.new
    outcomes = Queue.new
    thread_count = 4

    threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period.id), actor: User.find(staff_admin.id)).approve!
          outcomes << [ :approve, :ok ]
        rescue PayPeriodLifecycleService::Error => e
          outcomes << [ :approve, :domain_error, e.message ]
        rescue StandardError => e
          outcomes << [ :approve, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          EmployeePaymentDefaultService.new(
            employee: Employee.find(employee.id),
            method: "direct_deposit",
            actor: User.find(staff_admin.id)
          ).call
          outcomes << [ :payment_default, :ok ]
        rescue StandardError => e
          outcomes << [ :payment_default, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          EmployeeStatusTransitionService.deactivate!(
            employee: Employee.find(employee.id),
            actor: User.find(staff_admin.id),
            attributes: { effective_date: "2026-11-10", reason_category: "seasonal" }
          )
          outcomes << [ :staff_deactivate, :ok ]
        rescue EmployeeStatusTransitionService::Error => e
          outcomes << [ :staff_deactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes << [ :staff_deactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          EmployeeStatusTransitionService.terminate!(
            employee: Employee.find(employee.id),
            actor: User.find(client_manager.id),
            attributes: { effective_date: "2026-11-10", reason_category: "voluntary", source: "client_portal" }
          )
          outcomes << [ :client_terminate, :ok ]
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

    barrier2 = Queue.new
    outcomes2 = Queue.new
    round2_threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier2.pop
          PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period2.id), actor: User.find(staff_admin.id))
            .commit!(acknowledged_verification_items: ack_payload)
          outcomes2 << [ :commit, :ok ]
        rescue PayPeriodLifecycleService::Error => e
          outcomes2 << [ :commit, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :commit, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier2.pop
          EmployeeStatusTransitionService.reactivate!(
            employee: Employee.find(employee.id),
            actor: User.find(staff_admin.id),
            attributes: { effective_date: "2026-11-15" }
          )
          outcomes2 << [ :staff_reactivate, :ok ]
        rescue EmployeeStatusTransitionService::Error => e
          outcomes2 << [ :staff_reactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :staff_reactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier2.pop
          EmployeeStatusTransitionService.reactivate!(
            employee: Employee.find(employee.id),
            actor: User.find(client_manager.id),
            attributes: { effective_date: "2026-11-15", source: "client_portal" }
          )
          outcomes2 << [ :client_reactivate, :ok ]
        rescue EmployeeStatusTransitionService::Error => e
          outcomes2 << [ :client_reactivate, :domain_error, e.message ]
        rescue StandardError => e
          outcomes2 << [ :client_reactivate, :unexpected, e.class.name, e.message ]
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
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

    # Exactly one reactivate succeeded; never a deadlock or duplicate reactivate event.
    reactivate_oks = round2.count { |entry| entry[0].to_s.include?("reactivate") && entry[1] == :ok }
    expect(reactivate_oks).to eq(1)

    # If commit succeeded, its acknowledged verification item must never have been superseded.
    if round2.any? { |entry| entry == [ :commit, :ok ] }
      expect(verification_item.reload.status).to eq("pending_verification")
      expect(verification_item.acknowledged_in_committed_run?).to be(true)
    end
  ensure
    cleanup_non_transactional_company!(
      company: company,
      organization: organization,
      user_ids: [ staff_admin&.id, client_manager&.id ],
      tax_tables: tax_tables
    )
  end
end
