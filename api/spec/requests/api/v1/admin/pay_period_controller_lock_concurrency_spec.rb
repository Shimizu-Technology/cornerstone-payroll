# frozen_string_literal: true

require "rails_helper"
require "timeout"

module PayPeriodControllerLockConcurrencyHook
  private

  def with_financial_pay_period_lock
    queue = Thread.current[:pay_period_controller_lock_backend]
    queue << ApplicationRecord.connection.select_value("SELECT pg_backend_pid()") if queue
    super
  end
end

Api::V1::Admin::PayPeriodsController.prepend(PayPeriodControllerLockConcurrencyHook) unless
  Api::V1::Admin::PayPeriodsController < PayPeriodControllerLockConcurrencyHook

RSpec.describe "Admin pay-period financial locking", :postgres_concurrency, type: :request do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization, name: "Pay-period request concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:pay_period) { create(:pay_period, company: company, status: "draft") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)
  end

  after do
    PayPeriod.where(company_id: company.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "holds a protected update until the company and pay-period locks are released" do
    locked = Queue.new
    request_backend = Queue.new
    release_locks = Queue.new
    results = Queue.new
    locker_thread = nil
    request_thread = nil

    begin
      locker_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction do
            Company.lock.find(company.id)
            PayPeriod.lock.find(pay_period.id)
            locked << true
            release_locks.pop
          end
        end
      end
      pop_with_timeout(locked)

      request_thread = Thread.new do
        Thread.current[:pay_period_controller_lock_backend] = request_backend
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.patch(
          "/api/v1/admin/pay_periods/#{pay_period.id}",
          params: { pay_period: { run_purpose: "bonus" } }
        )
        results << [ session.response.status, JSON.parse(session.response.body) ]
      rescue StandardError => e
        results << [ :error, e ]
      ensure
        Thread.current[:pay_period_controller_lock_backend] = nil
      end

      wait_for_postgres_lock(pop_with_timeout(request_backend))
      expect(results).to be_empty
    ensure
      release_locks << true
      [ locker_thread, request_thread ].compact.each { |thread| Timeout.timeout(10) { thread.join } }
    end

    status, body = pop_with_timeout(results)
    expect(status).to eq(Rack::Utils.status_code(:ok)), body.inspect
    expect(pay_period.reload).to have_attributes(run_purpose: "bonus", includes_base_salary: false)
  end

  private

  def pop_with_timeout(queue, seconds: 10)
    queue.pop(timeout: seconds) || raise(Timeout::Error, "Timed out waiting for a queue value")
  rescue ThreadError
    raise Timeout::Error, "Timed out waiting for a queue value"
  end

  def wait_for_postgres_lock(backend_pid, seconds: 10)
    Timeout.timeout(seconds) do
      loop do
        waiting = ApplicationRecord.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE pid = #{Integer(backend_pid)} AND granted = false
          )
        SQL
        return if waiting

        sleep 0.01
      end
    end
  rescue Timeout::Error
    raise Timeout::Error, "Timed out waiting for PostgreSQL backend #{backend_pid} to wait on a lock"
  end
end
