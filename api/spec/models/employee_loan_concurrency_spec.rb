# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe EmployeeLoan, :postgres_concurrency, type: :model do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Loan Concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, name: "Loan Company #{SecureRandom.hex(4)}") }
  let!(:department) { Department.create!(company: company, name: "Loan concurrency") }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:loan) do
    described_class.create!(
      company: company,
      employee: employee,
      name: "Concurrency advance",
      original_amount: 500,
      current_balance: 500,
      payment_amount: 100,
      status: "active"
    )
  end

  after do
    LoanTransaction.where(employee_loan_id: loan.id).delete_all
    EmployeeLoan.where(id: loan.id).delete_all
    Employee.where(id: employee.id).delete_all
    Department.where(id: department.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "serializes competing payments against the latest balance" do
    ready, release = pause_first_update
    results = Queue.new

    first = payment_thread(results)
    ready.pop
    second = payment_thread(results)
    release << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    expect(2.times.map { results.pop }).to contain_exactly([ :ok, 100.to_d ], [ :ok, 100.to_d ])
    expect(loan.reload.current_balance).to eq(300)
    expect(loan.loan_transactions.order(:id).pluck(:balance_before, :balance_after)).to eq(
      [ [ 500.to_d, 400.to_d ], [ 400.to_d, 300.to_d ] ]
    )
  end

  it "serializes an addition behind an in-flight payment" do
    ready, release = pause_first_update
    results = Queue.new

    payment = payment_thread(results)
    ready.pop
    addition = addition_thread(results)
    release << true
    [ payment, addition ].each { |thread| Timeout.timeout(10) { thread.join } }

    expect(2.times.map { results.pop }.map(&:first)).to contain_exactly(:ok, :ok)
    expect(loan.reload.current_balance).to eq(450)
    expect(loan.loan_transactions.order(:id).pluck(:transaction_type, :balance_before, :balance_after)).to eq(
      [ [ "payment", 500.to_d, 400.to_d ], [ "addition", 400.to_d, 450.to_d ] ]
    )
  end

  [ :assignment, :definition ].each do |source|
    it "serializes a #{source} default edit behind payroll posting" do
      loan.update!(payment_amount: nil)
      period = create(:pay_period, company: company, pay_date: loan.balance_as_of)
      item = create(:payroll_item, company: company, employee: employee, pay_period: period)
      field = create(:payroll_field_definition, company: company, kind: "deduction", category: "loan", tax_treatment: "post_tax_deduction", default_amount: 100)
      assignment = EmployeePayrollField.create!(employee: employee, employee_loan: loan, payroll_field_definition: field, amount: source == :assignment ? 100 : nil)
      ready, release = pause_first_update
      results, edit_pid = Queue.new, Queue.new
      posting = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.find(loan.id).record_payment!(amount: 100.to_d, pay_period: period, payroll_item: item,
            schedule_snapshot: { "default" => true, "tracking_mode" => loan.tracking_mode,
              "payment_amount" => "", "first_deduction_date" => loan.first_deduction_date.to_s, "scheduled_request" => "100.0" })
          results << :posted
        rescue StandardError => e
          results << e
        end
      end
      Timeout.timeout(10) { ready.pop }
      editing = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          edit_pid << connection.select_value("SELECT pg_backend_pid()")
          source == :assignment ? EmployeePayrollField.find(assignment.id).update!(amount: 200) : PayrollFieldDefinition.find(field.id).update!(default_amount: 200)
          results << :edited
        rescue StandardError => e
          results << e
        end
      end
      pid = Timeout.timeout(10) { edit_pid.pop }
      Timeout.timeout(10) do
        loop do
          break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
          sleep 0.01
        end
      end
      release << true
      [ posting, editing ].each { |thread| Timeout.timeout(10) { thread.join } }
      expect(2.times.map { results.pop }).to contain_exactly(:posted, :edited)
      expect(loan.reload.current_balance).to eq(400)
      expect(loan.loan_transactions.payments.pluck(:amount)).to eq([ 100.to_d ])
      expect(source == :assignment ? assignment.reload.amount : field.reload.default_amount).to eq(200)
    ensure
      release << true if release
      [ posting, editing ].compact.each { |thread| Timeout.timeout(10) { thread.join } }
      item&.destroy!
      period&.destroy!
      assignment&.destroy!
      field&.destroy!
    end
  end

  it "serializes a reversed bulk schedule edit behind company-locked payroll posting" do
    actor = create(:user, company: company, organization: organization, role: "admin")
    allow_any_instance_of(Api::V1::Admin::EmployeePayrollFieldsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::EmployeePayrollFieldsController).to receive(:current_company_id).and_return(company.id)
    loans = [ loan, described_class.create!(company: company, employee: employee, name: "Second advance", original_amount: 500, current_balance: 500, payment_amount: 100) ]
    fields = loans.map { |ledger| create(:payroll_field_definition, company: company, name: "Schedule #{ledger.id}", kind: "deduction", category: "loan", tax_treatment: "post_tax_deduction", default_amount: 100) }
    assignments = loans.zip(fields).map { |ledger, field| EmployeePayrollField.create!(employee: employee, employee_loan: ledger, payroll_field_definition: field, amount: 100) }
    period = create(:pay_period, company: company, pay_date: loan.balance_as_of)
    item = create(:payroll_item, company: company, employee: employee, pay_period: period)
    ready, release = pause_first_update
    results, edit_pid = Queue.new, Queue.new
    posting = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Company.find(company.id).with_lock do
          loans.each { |ledger| described_class.find(ledger.id).record_payment!(amount: 100.to_d, pay_period: period, payroll_item: item) }
        end
        results << :posted
      rescue StandardError => e
        results << e
      end
    end
    Timeout.timeout(10) { ready.pop }
    editing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        edit_pid << connection.select_value("SELECT pg_backend_pid()")
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post("/api/v1/admin/employees/#{employee.id}/payroll_fields/bulk_update", params: {
          employee_payroll_fields: assignments.reverse.map { |assignment| { id: assignment.id, payroll_field_definition_id: assignment.payroll_field_definition_id, amount: 200, active: true } }
        })
        results << session.response.status
      rescue StandardError => e
        results << e
      end
    end
    pid = Timeout.timeout(10) { edit_pid.pop }
    Timeout.timeout(10) do
      loop do
        break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
        sleep 0.01
      end
    end
    release << true
    [ posting, editing ].each { |thread| Timeout.timeout(10) { thread.join } }
    expect(2.times.map { results.pop }).to contain_exactly(:posted, 200)
    expect(loans.map { |ledger| ledger.reload.current_balance }).to eq([ 400.to_d, 400.to_d ])
    expect(assignments.map { |assignment| assignment.reload.amount }).to eq([ 200.to_d, 200.to_d ])
  ensure
    release << true if release
    [ posting, editing ].compact.each { |thread| Timeout.timeout(10) { thread.join } }
    item&.destroy!
    period&.destroy!
    assignments&.each(&:destroy!)
    fields&.each(&:destroy!)
    if loans&.last && loans.last != loan
      loans.last.loan_transactions.delete_all
      loans.last.destroy!
    end
    actor&.destroy!
  end

  private

  def pause_first_update
    ready = Queue.new
    release = Queue.new
    pause_mutex = Mutex.new
    paused_once = false

    allow_any_instance_of(described_class).to receive(:update!).and_wrap_original do |original, *args|
      first_update = pause_mutex.synchronize do
        next false if paused_once

        paused_once = true
      end
      if first_update
        ready << true
        release.pop
      end
      original.call(*args)
    end

    [ ready, release ]
  end

  def payment_thread(results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        payment = described_class.find(loan.id).record_payment!(amount: 100)
        results << [ :ok, payment ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
  end

  def addition_thread(results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.find(loan.id).record_addition!(amount: 50)
        results << [ :ok, :addition ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
  end
end
