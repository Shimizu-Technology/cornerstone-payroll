# frozen_string_literal: true

require "rails_helper"
require "timeout"

# A pay-date correction holds the company while it waits for the period. A
# correction run created from that voided period must take the company first
# too, or its new run's company reference waits on the correction while the
# correction waits on its period lock.
RSpec.describe PayPeriodCorrectionService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { @organization = Organization.create!(name: "Correction Lock Order #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:source) do
    create(:pay_period, :voided, company: company, start_date: Date.new(2024, 7, 1), end_date: Date.new(2024, 7, 14),
      pay_date: Date.new(2024, 7, 19))
  end

  after { cleanup! }

  it "creates a correction run while a pay-date correction waits, without a deadlock" do
    run_creating = Queue.new
    release_run = Queue.new
    allow(PayPeriod).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:correction_run]
        run_creating << true
        release_run.pop
      end
      original.call(*args, **kwargs)
    end
    results = Queue.new
    backend = Queue.new

    creation = Thread.new do
      Thread.current[:correction_run] = true
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.create_correction_run!(source_pay_period: PayPeriod.find(source.id), actor: User.find(actor.id),
          reason: "Rerun the voided July payroll")
        results << [ :ok, :correction_run ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
    Timeout.timeout(10) { run_creating.pop }

    pay_date_correction = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        backend << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
        PayPeriodPayDateCorrectionService.call(pay_period: PayPeriod.find(source.id), new_pay_date: Date.new(2024, 7, 20),
          reason: "The July check was dated a day early", actor: User.find(actor.id))
        results << [ :ok, :pay_date_correction ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
    wait_for_database_lock!(backend.pop)
    release_run << true
    [ creation, pay_date_correction ].each { |thread| Timeout.timeout(15) { thread.join } }

    outcomes = 2.times.map { results.pop }
    expect(outcomes).to include([ :ok, :correction_run ])
    error = outcomes.find { |status, _| status == :error }&.last
    expect(error).to be_a(PayPeriodPayDateCorrectionService::Error)
    expect(error.message).to eq("Cannot correct the pay date on a voided pay period")
    expect(source.reload).to have_attributes(pay_date: Date.new(2024, 7, 19), superseded_by_id: be_present)
  end

  def wait_for_database_lock!(backend_pid)
    Timeout.timeout(5) do
      loop do
        state = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(backend_pid)}"
        )
        break if state == "Lock"

        sleep 0.01
      end
    end
  end

  # Only what this example committed; a fixture that failed to build is skipped.
  def cleanup!
    return unless @organization

    company_ids = Company.where(organization_id: @organization.id).pluck(:id)
    PayPeriodCorrectionEvent.where(company_id: company_ids).delete_all
    PayPeriod.where(company_id: company_ids).update_all(superseded_by_id: nil, source_pay_period_id: nil)
    PayPeriod.where(company_id: company_ids).delete_all
    AuditLog.where(company_id: company_ids).delete_all
    User.where(company_id: company_ids).delete_all
    Company.where(id: company_ids).delete_all
    Organization.where(id: @organization.id).delete_all
  end
end
