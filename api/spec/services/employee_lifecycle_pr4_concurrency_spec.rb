# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Staff lifecycle writes serialize with payroll", :postgres_concurrency do
  include EmployeeLifecyclePr4Helpers

  self.use_transactional_tests = false

  let!(:tax_tables) { ensure_verified_test_tax_years(2026) }
  let!(:company) { create(:company, name: "Fixture #{SecureRandom.hex(6)} Payroll Client", auto_create_fit_check: false) }
  let!(:actor) { create(:user, company: company, role: "org_admin", name: "Riley Admin", email: "riley.#{company.id}@example.test") }
  let!(:employee) { create_lifecycle_worker!(company, readiness_gate_enforced: gated) }
  let!(:period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
  end
  let(:gated) { false }

  before do
    unlock_lifecycle_mode!
    create_client_managed_profile!(company)
  end

  after do
    ApplicationRecord.transaction do
      PortalNotificationDelivery.where(company: company).delete_all
      PortalNotificationEvent.where(company: company).delete_all
      EmployeeReadinessOverride.where(company: company).delete_all
      connection = ApplicationRecord.connection
      connection.execute("ALTER TABLE admin_overrides DISABLE TRIGGER admin_overrides_append_only")
      AdminOverride.where(company: company).delete_all
      connection.execute("ALTER TABLE admin_overrides ENABLE TRIGGER admin_overrides_append_only")
      EmployeeVerificationItem.where(company: company).delete_all
      item_ids = PayrollItem.where(company: company).select(:id)
      PayrollItemEarning.where(payroll_item_id: item_ids).delete_all
      PayrollItemDeduction.where(payroll_item_id: item_ids).delete_all
      PayrollItem.where(company: company).delete_all
      EmployeeW4Election.where(company: company).delete_all
      EmployeeCompensationChange.where(company: company).delete_all
      AuditLog.where(company: company).delete_all
      company.pay_periods.delete_all
      company.employees.delete_all
      company.departments.delete_all
      ClientOperatingProfile.where(company: company).delete_all
      company.company_assignments.delete_all
      User.where(company: company).delete_all
      Company.where(id: company.id).delete_all
      Organization.where(id: company.organization_id).delete_all
    end
    tax_tables.each(&:destroy!)
  end

  def calculate_run!
    item = create(:payroll_item, company: company, employee: employee, pay_period: period)
    item.calculate!
    period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: actor.id)
  end

  def lifecycle
    PayPeriodLifecycleService.new(pay_period: PayPeriod.find(period.id), actor: actor)
  end

  def race_with_uncommitted_write(writer:, payroll:)
    writer_ready = Queue.new
    release_writer = Queue.new
    payroll_ready = Queue.new
    writer_thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        ApplicationRecord.transaction do
          writer.call
          writer_ready << connection.raw_connection.backend_pid
          release_writer.pop
        end
      end
    end
    writer_pid = Timeout.timeout(10) { writer_ready.pop }
    payroll_thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        payroll_ready << connection.raw_connection.backend_pid
        payroll.call
      rescue StandardError => error
        error
      end
    end
    payroll_pid = Timeout.timeout(10) { payroll_ready.pop }

    Timeout.timeout(10) do
      loop do
        blocked = ApplicationRecord.connection.select_value(
          "SELECT #{Integer(writer_pid)} = ANY(pg_blocking_pids(#{Integer(payroll_pid)}))"
        )
        break if blocked

        sleep 0.01
      end
    end

    release_writer << true
    Timeout.timeout(10) { writer_thread.value }
    Timeout.timeout(10) { payroll_thread.value }
  ensure
    release_writer << true
    [ writer_thread, payroll_thread ].compact.each do |thread|
      thread.join(10)
    end
  end

  it "rechecks acknowledgement revisions after a staff verification releases the company lock" do
    calculate_run!
    lifecycle.approve!
    item = EmployeeVerificationItem.create!(company: company, employee: employee, event_kind: "compensation_change",
      affects_pay: true, effective_on: period.end_date)
    acknowledged = [ { id: item.id, updated_at: item.updated_at.utc.iso8601(6) } ]

    error = race_with_uncommitted_write(
      writer: -> do
        EmployeeVerificationItems::Review.new(company_id: company.id, item_id: item.id, actor: actor).call!(:verify, {}) { }
      end,
      payroll: -> { lifecycle.commit!(acknowledged_verification_items: acknowledged) }
    )

    expect(error).to be_a(PayPeriodLifecycleService::CommitConflict)
    expect(error.code).to eq("unverified_changes_changed")
    expect(item.reload.status).to eq("verified")
    expect(period.reload).to be_approved
    expect(PayPeriodVerificationAcknowledgement.where(company: company)).to be_empty
  end

  context "for an incomplete hire" do
    let(:gated) { true }

    it "rechecks readiness after a revocation releases the company lock" do
      manager = EmployeeReadinessOverrides::Manage.new(company_id: company.id, employee_id: employee.id, actor: actor,
        verified: true, impersonated: false)
      override = manager.grant!(pay_period_id: period.id, default_w4_acknowledged: true,
        reason: "Allow the synthetic payroll test to proceed.")
      calculate_run!

      error = race_with_uncommitted_write(
        writer: -> { manager.revoke!(override_id: override.id, reason: "Revoke the synthetic payroll test exception.") },
        payroll: -> { lifecycle.approve! }
      )

      expect(error).to be_a(PayPeriodLifecycleService::InvalidTransitionError)
      expect(error.message).to include("W-4 missing")
      expect(override.reload.revoked_at).to be_present
      expect(period.reload).to be_calculated
    end
  end
end
