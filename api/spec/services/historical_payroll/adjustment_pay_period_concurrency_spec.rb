# frozen_string_literal: true

require "rails_helper"
require "timeout"

module HistoricalAdjustmentPayPeriodConcurrencyHook
  private

  def record_audit!(adjustment, preview)
    super
    Thread.current[:historical_adjustment_after_audit]&.call
  end
end

HistoricalPayroll::AdjustmentCreateService.prepend(HistoricalAdjustmentPayPeriodConcurrencyHook) unless
  HistoricalPayroll::AdjustmentCreateService < HistoricalAdjustmentPayPeriodConcurrencyHook

RSpec.describe "Historical adjustment and pay-period concurrency", :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Historical adjustment concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, historical_payroll_enabled: true) }
  let!(:department) { Department.create!(company: company, name: "Historical concurrency") }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:batch) do
    create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current, locked_by: actor)
  end
  let!(:historical_period) do
    HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "concurrency-historical-period",
      source_label: "QuickBooks concurrency payroll",
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 20),
      paycheck_count: 1
    )
  end
  let!(:worker) do
    create(
      :historical_worker,
      historical_import_batch: batch,
      company: company,
      employee: employee,
      mapping_status: "exact_match"
    )
  end
  let!(:paycheck) do
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: historical_period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "concurrency-historical-paycheck",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: historical_period.start_date,
      period_end: historical_period.end_date,
      pay_date: historical_period.pay_date,
      gross_pay: 1_000,
      adjusted_gross: 1_000,
      net_pay: 1_000,
      total_payroll_cost: 1_000
    )
  end
  let!(:bootstrap) do
    create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      created_by: actor,
      applied_by: actor,
      applied_at: Time.current,
      status: "applied"
    )
  end
  let!(:bridge) do
    HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      created_by: actor,
      applied_by: actor,
      applied_at: Time.current,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT,
      status: "applied",
      revision: 1,
      plan_digest: Digest::SHA256.hexdigest("concurrency-ytd-plan"),
      preview_summary: {
        "through_period_end" => historical_period.end_date.iso8601,
        "through_pay_date" => historical_period.pay_date.iso8601,
        "adjustment_digest" => HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest
      }
    )
  end
  let!(:pay_period) do
    bridge
    create(
      :pay_period,
      company: company,
      status: "calculated",
      start_date: Date.new(2026, 3, 21),
      end_date: Date.new(2026, 4, 3),
      pay_date: Date.new(2026, 4, 9)
    )
  end

  after do
    cleanup_records
  end

  it "makes approval observe an adjustment that is committing concurrently" do
    adjustment_at_audit = Queue.new
    release_adjustment = Queue.new
    results = Queue.new
    attributes = {
      kind: "correction",
      effective_pay_date: paycheck.pay_date.iso8601,
      reason: "Concurrency regression",
      idempotency_key: "historical-adjustment-concurrency",
      gross_pay: 25,
      net_pay: 25
    }
    preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: attributes
    ).call

    adjustment_thread = nil
    approval_thread = nil
    begin
      adjustment_thread = Thread.new do
        Thread.current[:historical_adjustment_after_audit] = lambda do
          adjustment_at_audit << true
          release_adjustment.pop
        end
        ActiveRecord::Base.connection_pool.with_connection do
          thread_paycheck = HistoricalPaycheck.find(paycheck.id)
          thread_actor = User.find(actor.id)
          HistoricalPayroll::AdjustmentCreateService.new(
            paycheck: thread_paycheck,
            actor: thread_actor,
            attributes: attributes,
            acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
            preview_digest: preview.digest
          ).call
          results << [ :ok, :adjustment ]
        rescue StandardError => e
          results << [ :error, e ]
        ensure
          Thread.current[:historical_adjustment_after_audit] = nil
        end
      end
      pop_with_timeout(adjustment_at_audit)

      approval_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          thread_period = PayPeriod.find(pay_period.id)
          thread_actor = User.find(actor.id)
          PayPeriodLifecycleService.new(pay_period: thread_period, actor: thread_actor).approve!
          results << [ :ok, :approval ]
        rescue StandardError => e
          results << [ :error, e ]
        end
      end
      expect { pop_with_timeout(results, seconds: 0.2) }.to raise_error(Timeout::Error)
    ensure
      release_adjustment << true
      [ adjustment_thread, approval_thread ].compact.each { |thread| Timeout.timeout(10) { thread.join } }
    end
    outcomes = 2.times.map { pop_with_timeout(results) }

    expect(outcomes).to include([ :ok, :adjustment ])
    approval_error = outcomes.filter_map { |status, value| value if status == :error }.sole
    expect(approval_error).to be_an(ActiveRecord::RecordInvalid)
    expect(approval_error.record.errors[:base]).to include(/revised historical YTD bridge/)
    expect(pay_period.reload).to be_calculated
  end

  private

  def pop_with_timeout(queue, seconds: 10)
    queue.pop(timeout: seconds) || raise(Timeout::Error, "Timed out waiting for a queue value")
  rescue ThreadError
    raise Timeout::Error, "Timed out waiting for a queue value"
  end

  def cleanup_records
    company_id = company.id
    HistoricalPaycheckAdjustmentEvent.where(company_id: company_id).delete_all
    HistoricalPaycheckAdjustment.where(company_id: company_id).delete_all
    HistoricalEmployeeYtdBalance.where(company_id: company_id).delete_all
    HistoricalYtdBridge.where(company_id: company_id).delete_all
    bootstrap_ids = HistoricalClientBootstrap.where(company_id: company_id).select(:id)
    HistoricalClientBootstrapDispatch.where(historical_client_bootstrap_id: bootstrap_ids).delete_all
    HistoricalClientBootstrap.where(company_id: company_id).delete_all
    HistoricalImportCutoverReview.where(company_id: company_id).delete_all
    HistoricalPaycheck.where(company_id: company_id).delete_all
    HistoricalPayPeriod.where(company_id: company_id).delete_all
    HistoricalWorker.where(company_id: company_id).delete_all
    HistoricalImportSourceFile.where(company_id: company_id).delete_all
    HistoricalImportBatch.where(company_id: company_id).delete_all
    PayrollItem.where(company_id: company_id).delete_all
    PayPeriod.where(company_id: company_id).delete_all
    AuditLog.where(company_id: company_id).delete_all
    Employee.where(company_id: company_id).delete_all
    Department.where(company_id: company_id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company_id).delete_all
    Organization.where(id: organization.id).delete_all
  end
end
