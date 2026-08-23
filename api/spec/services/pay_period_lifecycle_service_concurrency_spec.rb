# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayPeriodLifecycleService, :postgres_concurrency, type: :service do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Lifecycle Concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, auto_create_fit_check: false) }
  let!(:department) { Department.create!(company: company, name: "Concurrency") }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      status: "approved",
      approved_at: Time.current,
      approved_by_id: actor.id,
      pay_date: Date.current + 3.days
    )
  end
  let!(:payroll_item) do
    create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: employee,
      gross_pay: 1_200,
      net_pay: 1_008.20,
      withholding_tax: 100,
      social_security_tax: 74.40,
      medicare_tax: 17.40,
      employer_social_security_tax: 74.40,
      employer_medicare_tax: 17.40
    )
  end

  after do
    cleanup_concurrency_records
  end

  it "applies commit side effects exactly once when two commits compete" do
    first_at_posting, release_first = pause_first_commit_at_liability_posting
    results = Queue.new

    first = lifecycle_thread(results, :commit!)
    first_at_posting.pop
    second = lifecycle_thread(results, :commit!)
    release_first << true
    [ first, second ].each { |thread| Timeout.timeout(10) { thread.join } }

    outcomes = 2.times.map { results.pop }
    expect(outcomes.count { |status, _| status == :ok }).to eq(1)
    expect(outcomes.filter_map { |status, value| value if status == :error })
      .to contain_exactly(an_instance_of(PayPeriodLifecycleService::InvalidTransitionError))
    expect_exactly_once_commit_effects
  end

  it "does not let a delayed unapprove overwrite a completed commit" do
    first_at_posting, release_first = pause_first_commit_at_liability_posting
    results = Queue.new

    commit_thread = lifecycle_thread(results, :commit!)
    first_at_posting.pop
    unapprove_thread = lifecycle_thread(results, :unapprove!)
    release_first << true
    [ commit_thread, unapprove_thread ].each { |thread| Timeout.timeout(10) { thread.join } }

    outcomes = 2.times.map { results.pop }
    expect(outcomes.count { |status, _| status == :ok }).to eq(1)
    expect(outcomes.filter_map { |status, value| value if status == :error })
      .to contain_exactly(an_instance_of(PayPeriodLifecycleService::InvalidTransitionError))
    expect_exactly_once_commit_effects
    expect(pay_period.reload).to have_attributes(
      status: "committed",
      approved_by_id: actor.id,
      unapproved_at: nil,
      unapproved_by_id: nil
    )
  end

  private

  def lifecycle_thread(results, operation)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        period = PayPeriod.find(pay_period.id)
        thread_actor = User.find(actor.id)
        described_class.new(pay_period: period, actor: thread_actor, ip_address: "127.0.0.1").public_send(operation)
        results << [ :ok, operation ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
  end

  def pause_first_commit_at_liability_posting
    first_at_posting = Queue.new
    release_first = Queue.new
    call_count = 0
    mutex = Mutex.new

    allow(PayrollLiabilityPostingService).to receive(:post!).and_wrap_original do |original, **kwargs|
      first_call = mutex.synchronize do
        call_count += 1
        call_count == 1
      end
      if first_call
        first_at_posting << true
        release_first.pop
      end
      original.call(**kwargs)
    end

    [ first_at_posting, release_first ]
  end

  def expect_exactly_once_commit_effects
    expect(pay_period.reload.status).to eq("committed")
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: pay_period.pay_date.year).gross_pay).to eq(1_200)
    expect(CompanyYtdTotal.find_by!(company: company, year: pay_period.pay_date.year).gross_pay).to eq(1_200)
    expect(pay_period.payroll_liability_postings.where(posting_type: "commit").count).to eq(1)
    expect(payroll_item.check_events.where(event_type: "assigned").count).to eq(1)
  end

  def cleanup_concurrency_records
    company_id = company.id
    employee_id = employee.id
    pay_period_id = pay_period.id
    payroll_item_ids = PayrollItem.where(pay_period_id: pay_period_id).pluck(:id)

    CheckEvent.where(payroll_item_id: payroll_item_ids).delete_all
    PayrollLiabilityEntry.where(company_id: company_id).delete_all
    PayrollLiabilityPosting.where(company_id: company_id).delete_all
    PayrollItemDeduction.where(payroll_item_id: payroll_item_ids).delete_all
    PayrollItem.where(id: payroll_item_ids).delete_all
    EmployeeYtdTotal.where(employee_id: employee_id).delete_all
    CompanyYtdTotal.where(company_id: company_id).delete_all
    PayPeriod.where(id: pay_period_id).delete_all
    Employee.where(id: employee_id).delete_all
    Department.where(id: department.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company_id).delete_all
    Organization.where(id: organization.id).delete_all
  end
end
