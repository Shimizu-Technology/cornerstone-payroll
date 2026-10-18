# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "QuickBooks bootstrap authorization at delayed boundaries", :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: :org_admin) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: :accountant) }
  let!(:assignment) { create(:company_assignment, company: company, user: actor, granted_by: admin, client_management: true) }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(
      company: company, files: quickbooks_history_uploads + quickbooks_tax_wage_uploads, actor: admin
    ).call.batch
  end

  after do
    employee_ids = Employee.where(company_id: company.id).pluck(:id)
    HistoricalPaycheckAdjustmentEvent.where(company_id: company.id).delete_all
    HistoricalPaycheckAdjustment.where(company_id: company.id).delete_all
    HistoricalEmployeeYtdBalance.where(company_id: company.id).delete_all
    HistoricalYtdBridge.where(company_id: company.id).delete_all
    HistoricalClientBootstrapDispatch.where(historical_client_bootstrap_id: batch.historical_client_bootstrap&.id).delete_all
    HistoricalClientBootstrap.where(company_id: company.id).delete_all
    HistoricalImportCutoverReview.where(company_id: company.id).delete_all
    HistoricalPaycheck.where(company_id: company.id).delete_all
    HistoricalPayPeriod.where(company_id: company.id).delete_all
    HistoricalWorker.where(company_id: company.id).delete_all
    HistoricalTaxWageReport.where(company_id: company.id).delete_all
    HistoricalImportSourceFile.where(historical_import_batch_id: batch.id).delete_all
    HistoricalImportBatch.where(id: batch.id).delete_all
    EmployeeW4Election.where(employee_id: employee_ids).delete_all
    EmployeeWageRate.where(employee_id: employee_ids).delete_all
    EmployeePayrollField.where(employee_id: employee_ids).delete_all
    PayrollFieldDefinition.where(company_id: company.id).delete_all
    Employee.where(id: employee_ids).delete_all
    AuditLog.where(company_id: company.id).delete_all
    CompanyAssignment.where(company_id: company.id).delete_all
    User.where(id: [ actor.id, admin.id ]).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: company.organization_id).delete_all
  end

  def preview_bootstrap
    QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: admin).call.tap do |bootstrap|
      expect(bootstrap).to be_ready_to_apply
      expect(QuickbooksHistory::ClientBootstrapPlan.new(batch: batch).call).to be_ready
    end
  end

  def preview_bridge(with_adjustment: false)
    bootstrap = preview_bootstrap
    QuickbooksHistory::ClientBootstrapApplyService.new(
      bootstrap: bootstrap, actor: admin, acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    approve_historical_cutover(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).lock!
    if with_adjustment
      paycheck = batch.historical_paychecks.order(:id).first
      input = { kind: "correction", effective_pay_date: paycheck.pay_date.iso8601, reason: "Correct retained wages",
                idempotency_key: "revocation-ytd-adjustment", gross_pay: 100, federal_income_tax: 10,
                social_security_tax: 6.20, medicare_tax: 1.45 }
      preview = HistoricalPayroll::AdjustmentPreviewService.new(paycheck: paycheck, actor: admin, attributes: input).call
      adjustment = HistoricalPayroll::AdjustmentCreateService.new(
        paycheck: paycheck, actor: admin, attributes: input, preview_digest: preview.digest,
        acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT
      ).call
      HistoricalPayroll::AdjustmentEventService.new(
        adjustment: adjustment, actor: admin, event_type: "filing_reviewed_no_amendment"
      ).call
    end
    QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: admin).call.tap do |bridge|
      expect(bridge).to be_ready_to_apply
      expect(QuickbooksHistory::YtdBridgePlan.new(batch: batch).call).to be_ready
    end
  end

  def enqueue_service(bootstrap, user = actor)
    QuickbooksHistory::ClientBootstrapEnqueueService.new(
      bootstrap: bootstrap, actor: user, acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    )
  end

  # The holder commits revocation on one connection only after PostgreSQL proves
  # the previously authorized operation is waiting on its business row lock.
  def revoke_while_blocked(record, error_class: QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, &operation)
    waiting = Queue.new
    result = Queue.new
    connection = ActiveRecord::Base.connection
    thread = nil
    record.class.transaction do
      record.lock!
      allow_any_instance_of(record.class).to receive(:lock!).and_wrap_original do |original, *args|
        waiting << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()") if original.receiver.id == record.id
        original.call(*args)
      end
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          operation.call
          result << :unexpected_success
        rescue StandardError => e
          result << e
        end
      end
      blocked_pid = Timeout.timeout(10) { waiting.pop }
      Timeout.timeout(10) do
        until connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(blocked_pid)})) > 0")
          sleep 0.01
        end
      end
      assignment.update!(client_management: false)
    end
    Timeout.timeout(10) { thread.join }
    expect(result.pop).to be_a(error_class)
    expect(assignment.reload.client_management).to be(false)
  ensure
    Timeout.timeout(10) { thread&.join }
  end

  it "preserves the existing bootstrap preview and audit when its batch lock delays a revoked preview" do
    bootstrap = preview_bootstrap
    before_state = bootstrap.attributes
    audits = AuditLog.where(company_id: company.id).count
    revoke_while_blocked(batch) do
      QuickbooksHistory::ClientBootstrapPreviewService.new(batch: HistoricalImportBatch.find(batch.id), actor: User.find(actor.id)).call
    end
    expect(bootstrap.reload.attributes).to eq(before_state)
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "creates no pending state, dispatch, job or audit after revocation during a valid enqueue's bootstrap lock wait" do
    bootstrap = preview_bootstrap
    before_state = bootstrap.attributes
    audits = AuditLog.where(company_id: company.id).count
    expect(QuickbooksHistory::ClientBootstrapJob).not_to receive(:perform_later)
    revoke_while_blocked(bootstrap) do
      enqueue_service(HistoricalClientBootstrap.find(bootstrap.id), User.find(actor.id)).call
    end
    expect(bootstrap.reload.attributes).to eq(before_state)
    expect(bootstrap.historical_client_bootstrap_dispatches).to be_empty
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "creates no employee setup, links or audit after revocation during a valid apply's final bootstrap lock wait" do
    bootstrap = preview_bootstrap
    audits = AuditLog.where(company_id: company.id).count
    revoke_while_blocked(bootstrap) do
      QuickbooksHistory::ClientBootstrapApplyService.new(
        bootstrap: HistoricalClientBootstrap.find(bootstrap.id), actor: User.find(actor.id),
        acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
      ).call
    end
    expect(bootstrap.reload).to be_previewed
    expect(company.employees).to be_empty
    expect(EmployeeW4Election.count).to eq(0)
    expect(EmployeeWageRate.count).to eq(0)
    expect(EmployeePayrollField.count).to eq(0)
    expect(batch.historical_workers.where.not(employee_id: nil)).to be_empty
    expect(batch.historical_paychecks.where.not(employee_id: nil)).to be_empty
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "preserves cutover evidence and audit after revocation during verification's final batch lock wait" do
    review_historical_workers_as_archive_only(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    review = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    before_state = review.attributes
    audits = AuditLog.where(company_id: company.id).count
    revoke_while_blocked(batch, error_class: QuickbooksHistory::CutoverVerificationService::UnauthorizedVerificationAttempt) do
      QuickbooksHistory::CutoverVerificationService.new(
        batch: HistoricalImportBatch.find(batch.id), actor: User.find(actor.id),
        expected_verification_started_at: review.verification_started_at.iso8601(6)
      ).call
    end
    expect(review.reload.attributes).to eq(before_state)
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "preserves the YTD preview, revision and audit after revocation during the batch lock wait" do
    bridge = preview_bridge
    before_state = bridge.attributes
    audits = AuditLog.where(company_id: company.id).count
    revoke_while_blocked(batch) do
      QuickbooksHistory::YtdBridgePreviewService.new(batch: HistoricalImportBatch.find(batch.id), actor: User.find(actor.id)).call
    end
    expect(bridge.reload.attributes).to eq(before_state)
    expect(batch.historical_ytd_bridges.count).to eq(1)
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "inserts no balances, activation events, applied transition or audit after revocation during a valid YTD apply's bridge lock wait" do
    bridge = preview_bridge(with_adjustment: true)
    expect(bridge.preview_summary.fetch("adjustment_ids")).not_to be_empty
    audits = AuditLog.where(company_id: company.id).count
    revoke_while_blocked(bridge) do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: HistoricalYtdBridge.find(bridge.id), actor: User.find(actor.id),
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call
    end
    expect(bridge.reload).to have_attributes(status: "previewed", applied_at: nil, applied_by_id: nil)
    expect(bridge.historical_employee_ytd_balances).to be_empty
    expect(HistoricalPaycheckAdjustmentEvent.where(company_id: company.id, event_type: "ytd_revision_activated")).to be_empty
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "rechecks after preparation commits, preserving accepted pending evidence without a first dispatch" do
    bootstrap = preview_bootstrap
    service = enqueue_service(bootstrap)
    allow(service).to receive(:prepare_pending_bootstrap!).and_wrap_original do |original|
      prepared = original.call
      assignment.update!(client_management: false)
      prepared
    end
    expect(QuickbooksHistory::ClientBootstrapJob).not_to receive(:perform_later)
    expect { service.call }.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
    expect(bootstrap.reload).to be_pending
    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    expect(dispatch).to have_attributes(dispatch_attempts: 0, enqueued_at: nil, last_error: nil, completed_at: nil)
    # Automatic recovery cannot bypass the final boundary for an unsent request.
    expect { HistoricalClientBootstrapDispatch.dispatch_pending!(ids: [ dispatch.id ]) }.not_to change { dispatch.reload.attributes }
    expect(AuditLog.where(company_id: company.id, action: "historical_imports#queue_client_bootstrap").count).to eq(1)
  end

  it "rechecks a first dispatch after its own real lock wait and leaves existing evidence intact" do
    bootstrap = preview_bootstrap
    allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).and_raise("queue unavailable")
    enqueue_service(bootstrap, admin).call
    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    dispatch.update!(requested_by: actor)
    before_state = dispatch.attributes
    audits = AuditLog.where(company_id: company.id).count
    expect(QuickbooksHistory::ClientBootstrapJob).not_to receive(:perform_later)
    revoke_while_blocked(dispatch) do
      HistoricalClientBootstrapDispatch.find(dispatch.id).dispatch!(authorization_actor: User.find(actor.id))
    end
    expect(dispatch.reload.attributes).to eq(before_state)
    expect(bootstrap.reload).to be_pending
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  it "rechecks in a short transaction after dispatch locks release, without recording a denied attempt" do
    bootstrap = preview_bootstrap
    service = enqueue_service(bootstrap)
    allow_any_instance_of(HistoricalClientBootstrapDispatch).to receive(:with_business_locks).and_wrap_original do |original, *args, &block|
      prepared = original.call(*args, &block)
      assignment.update!(client_management: false)
      prepared
    end
    expect(QuickbooksHistory::ClientBootstrapJob).not_to receive(:perform_later)
    expect { service.call }.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
    expect(bootstrap.reload.historical_client_bootstrap_dispatches.sole).to have_attributes(dispatch_attempts: 0, enqueued_at: nil)
  end

  it "holds no row locks during queue transport and writes no failure state after transport-time revocation" do
    bootstrap = preview_bootstrap
    allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later) do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      assignment.update!(client_management: false)
      raise "queue unavailable"
    end
    expect { enqueue_service(bootstrap).call }.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
    expect(bootstrap.reload).to have_attributes(status: "pending", apply_error: nil)
    expect(bootstrap.historical_client_bootstrap_dispatches.sole).to have_attributes(
      dispatch_attempts: 0, enqueued_at: nil, completed_at: nil, last_error: nil
    )
  end

  it "preserves dispatched evidence and automatic retry semantics after later revocation" do
    bootstrap = preview_bootstrap
    expect(enqueue_service(bootstrap).call.enqueued).to be(true)
    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    dispatch.update!(enqueued_at: 31.minutes.ago)
    assignment.update!(client_management: false)
    expect(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).with(bootstrap.id, actor.id, dispatch.attempt_token)
    expect(dispatch.dispatch!).to be(true)
    expect(dispatch.reload.dispatch_attempts).to eq(2)
    # The accepted dispatch is evidence, not permission to activate live records.
    audits = AuditLog.where(company_id: company.id).count
    QuickbooksHistory::ClientBootstrapJob.perform_now(bootstrap.id, actor.id, dispatch.attempt_token)
    expect(bootstrap.reload).to be_pending
    expect(company.employees).to be_empty
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end

  [ false, true ].each do |first_send_accepted|
    it "lets an admin resume and apply a revoked accountant's #{first_send_accepted ? 'accepted' : 'unsent'} pending attempt" do
      bootstrap = preview_bootstrap
      unless first_send_accepted
        allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).and_raise("Synthetic queue outage")
      end
      expect(enqueue_service(bootstrap).call.enqueued).to be(first_send_accepted)
      dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
      original_token = dispatch.attempt_token
      queue_audit = AuditLog.find_by!(company_id: company.id, action: "historical_imports#queue_client_bootstrap")
      expect(queue_audit.user_id).to eq(actor.id)
      assignment.update!(client_management: false)
      dispatch.update!(enqueued_at: 31.minutes.ago) if first_send_accepted
      allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later).and_call_original

      expect(enqueue_service(bootstrap, admin).call.enqueued).to be(true)

      expect(dispatch.reload).to have_attributes(requested_by_id: admin.id, attempt_token: original_token)
      expect(bootstrap.historical_client_bootstrap_dispatches.count).to eq(1)
      expect(QuickbooksHistory::ClientBootstrapJob).to have_received(:perform_later).with(bootstrap.id, admin.id, original_token)
      expect(queue_audit.reload.user_id).to eq(actor.id)
      resume_audit = AuditLog.find_by!(company_id: company.id, action: "historical_imports#resume_client_bootstrap")
      expect(resume_audit.user_id).to eq(admin.id)
      expect(resume_audit.metadata).to include("previous_requester_id" => actor.id, "requested_by_id" => admin.id)

      # Durable recovery also retains the replacement operator, rather than
      # reverting to the original revoked requester on the next retry.
      dispatch.update!(enqueued_at: 31.minutes.ago)
      expect(dispatch.dispatch!).to be(true)
      expect(QuickbooksHistory::ClientBootstrapJob).to have_received(:perform_later).with(bootstrap.id, admin.id, original_token).twice
      QuickbooksHistory::ClientBootstrapJob.perform_now(bootstrap.id, admin.id, original_token)
      expect(bootstrap.reload).to have_attributes(status: "applied", applied_by_id: admin.id)
      expect(company.employees.count).to eq(2)
      expect(dispatch.reload.completed_at).to be_present
    end
  end

  it "keeps delegated employee preparation and historical YTD activation available with a live exact grant" do
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    expect(bootstrap).to be_ready_to_apply
    QuickbooksHistory::ClientBootstrapApplyService.new(
      bootstrap: bootstrap, actor: actor, acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    approve_historical_cutover(batch, actor: admin)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: admin).lock!
    bridge = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    expect(bridge).to be_ready_to_apply
    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: bridge, actor: actor, acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call
    expect(bridge.reload).to have_attributes(status: "applied", applied_by_id: actor.id)
    expect(bridge.historical_employee_ytd_balances.count).to eq(2)
  end

  it "serializes concurrent dispatchers without holding business locks through an accepted queue submission" do
    bootstrap = preview_bootstrap
    service = enqueue_service(bootstrap)
    service.send(:prepare_pending_bootstrap!)
    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    entered = Queue.new
    release = Queue.new
    result = Queue.new
    allow(QuickbooksHistory::ClientBootstrapJob).to receive(:perform_later) do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      entered << true
      Timeout.timeout(10) { release.pop }
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result << HistoricalClientBootstrapDispatch.find(dispatch.id).dispatch!
      rescue StandardError => e
        result << e
      end
    end
    Timeout.timeout(10) { entered.pop }
    expect(HistoricalClientBootstrapDispatch.find(dispatch.id).dispatch!).to be(false)
    # Another connection can acquire every business/auth row during transport.
    Company.transaction do
      company.lock!("FOR UPDATE NOWAIT")
      batch.lock!("FOR UPDATE NOWAIT")
      bootstrap.lock!("FOR UPDATE NOWAIT")
      dispatch.lock!("FOR UPDATE NOWAIT")
      actor.lock!("FOR UPDATE NOWAIT")
      assignment.lock!("FOR UPDATE NOWAIT")
      assignment.update!(client_management: false)
    end
    release << true
    Timeout.timeout(10) { thread.join }
    expect(result.pop).to be(true)
    expect(dispatch.reload).to have_attributes(dispatch_attempts: 1, enqueued_at: be_present, last_error: nil)
    expect(QuickbooksHistory::ClientBootstrapJob).to have_received(:perform_later).once
  ensure
    release << true if release
    Timeout.timeout(10) { thread&.join }
  end


  it "does not turn delayed background failure bookkeeping into a write or audit after revocation" do
    bootstrap = preview_bootstrap
    enqueue_service(bootstrap).call
    dispatch = bootstrap.historical_client_bootstrap_dispatches.sole
    before_state = dispatch.attributes
    audits = AuditLog.where(company_id: company.id).count
    allow(QuickbooksHistory::ClientBootstrapApplyService).to receive(:new).and_raise("synthetic setup failure")
    allow_any_instance_of(HistoricalClientBootstrap).to receive(:lock!).and_wrap_original do |original, *args|
      assignment.update!(client_management: false)
      original.call(*args)
    end
    QuickbooksHistory::ClientBootstrapJob.perform_now(bootstrap.id, actor.id, dispatch.attempt_token)
    expect(bootstrap.reload).to have_attributes(status: "pending", apply_error: nil)
    expect(dispatch.reload.attributes).to eq(before_state)
    expect(company.employees).to be_empty
    expect(AuditLog.where(company_id: company.id).count).to eq(audits)
  end
end
