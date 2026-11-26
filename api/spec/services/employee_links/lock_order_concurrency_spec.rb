# frozen_string_literal: true

require "rails_helper"
require "timeout"

# Two real connections. A contact edit locks the company FOR UPDATE and then
# the employee; the sign-up and claim check (Verify) locks the employee and
# then inserts a row naming the company, whose foreign-key check needs a
# share lock on the company. Unless Verify takes the company first, the two
# wait on each other and PostgreSQL aborts one as a deadlock.
RSpec.describe EmployeeLinks::Verify, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Lock Order #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, name: "Lock Order Bakery #{SecureRandom.hex(4)}") }
  let!(:department) { Department.create!(company: company, name: "Lock order") }
  let!(:staff) { create(:user, company: company, organization: organization, role: :admin) }
  let!(:employee) do
    create(:employee, company: company, department: department, email: "lock.order@example.net", date_of_birth: Date.new(1990, 4, 12))
  end
  let!(:issued) do
    link = EmployeeAccountLink.new(company: company, employee: employee, invited_by: staff, status: "invited")
    credentials = EmployeeLinks::Credentials.issue(link, delivery: "code", issued_by_staff: true)
    link.save!
    [ link, credentials.code ]
  end

  # The app switch isn't under test; the check needs the link usable.
  before { allow_any_instance_of(EmployeeAccountLink).to receive(:portal_enabled?).and_return(true) }

  after do
    AuditLog.where(company_id: company.id).delete_all
    EmployeeAccountLink.where(company_id: company.id).delete_all
    EmployeeCompensationChange.where(employee_id: employee.id).delete_all
    Employee.where(id: employee.id).delete_all
    Department.where(id: department.id).delete_all
    User.where(id: staff.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  def system(&block)
    TenantScope.as_system(reason: "Spec: lock order across two connections", &block)
  end

  def waiting_on_lock?(pid)
    ActiveRecord::Base.connection.select_value(
      "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
    ) == "Lock"
  end

  it "lets a contact edit wait for the check instead of deadlocking with it" do
    link, code = issued
    results = Queue.new
    holding = Queue.new
    release = Queue.new
    edit_pid = Queue.new

    check = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        system do
          outcome = described_class.call(token: nil, code: code, date_of_birth: "1990-04-12",
            ssn_last4: employee.ssn_digits.last(4)) do |locked|
            holding << true
            Timeout.timeout(10) { release.pop }
            # A row naming the company, as a sign-up's login or audit row is.
            AuditLog.record!(actor: AuditActor.system_job("Spec"), organization_id: organization.id, company_id: company.id,
              action: "spec#lock_order_probe", record_type: "companies", record_id: company.id)
            locked
          end
          results << (outcome ? :checked : :refused)
        end
      rescue StandardError => error
        results << error.class
      end
    end
    Timeout.timeout(10) { holding.pop }

    edit = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        edit_pid << connection.select_value("SELECT pg_backend_pid()")
        system do
          Employee.transaction do
            Company.lock.find(company.id)
            Employee.lock.find(employee.id).update!(phone: "671-555-0142")
          end
        end
        results << :edited
      rescue StandardError => error
        results << error.class
      end
    end

    pid = Timeout.timeout(10) { edit_pid.pop }
    Timeout.timeout(10) { sleep 0.01 until waiting_on_lock?(pid) }
    release << true
    [ check, edit ].each { |thread| Timeout.timeout(15) { thread.join } }

    expect(2.times.map { results.pop }).to contain_exactly(:checked, :edited)
    expect(link.reload.failed_activation_attempts).to eq(0)
    expect(employee.reload.phone).to be_present
  ensure
    release << true
    [ check, edit ].compact.each { |thread| Timeout.timeout(15) { thread.join } }
  end
end
