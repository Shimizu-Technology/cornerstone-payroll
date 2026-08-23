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
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "serializes competing payments against the latest balance" do
    ready = Queue.new
    release = Queue.new
    results = Queue.new
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

  private

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
end
