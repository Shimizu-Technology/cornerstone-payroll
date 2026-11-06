# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Financial correction Source lineage" do
  include_context "exact source correction fixtures"
  before(:context) do
    FileUtils.mkdir_p(Rails.root.join("tmp"))
    File.open(Rails.root.join("tmp/financial_correction_migrated_schema.rb"), "w") do |file|
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, file)
    end
  end
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1 payment_cancellation_v1], identity_verified_at: Time.current)
  end
  let(:original_payment_state) { "unprepared" }

  def committed_correction
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct the mistaken deduction")
    correction = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct the mistaken deduction")
    item = correction.payroll_items.find_by!(employee: employee)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    correction.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: correction, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    [ correction.reload, item.reload ]
  end

  it "records a Source commit for the actual corrected period/item through existing financial services" do
    correction, item = committed_correction
    expect(correction).to be_committed
    expect(item.net_pay).to eq(92.35)
    receipts = AirePayrollEntryAcknowledgement.where(payroll_item: item, status: "committed")
    expect(receipts.count).to eq(1)
    expect(original_import.reload.pay_period_id).to eq(original_period.id)
    expect(allocation.reload.payroll_item_id).to eq(original_item.id)
  end

  it "holds package preparation while a Source-backed correction has no accepted successor receipt" do
    _correction, item = committed_correction
    expect { item.mark_package_prepared!(user: actor) }.to raise_error(ArgumentError, /source/i)
    expect(item.reload.check_prepared_at).to be_nil
    expect(item.check_events.where(event_type: "prepared")).to be_empty
  end

  it "holds legacy direct marking as printed without authoritative corrected Source coverage" do
    _correction, item = committed_correction
    expect { item.mark_printed!(user: actor) }.to raise_error(ArgumentError, /source/i)
    expect(item.reload.check_print_count).to eq(0)
  end
end

RSpec.describe "Financial correction ownership recovery" do
  include_context "exact source correction fixtures"
  let(:original_payment_state) { "unprepared" }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1 payment_cancellation_v1], identity_verified_at: Time.current)
  end

  def build_correction(commit: true, legacy: false, bonus: nil)
    if legacy
      allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=)
      allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_return([])
    end
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct the mistaken deduction")
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct the mistaken deduction")
    item = period.payroll_items.find_by!(employee: employee)
    if bonus
      PayrollBonusInput.manual!(item, bonus)
      item.save!
    end
    period.payroll_items.each { |row| PayrollCalculator.for(row.employee, row).calculate; row.save! }
    period.update!(status: "calculated")
    life = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    life.approve!
    life.commit! if commit
    if legacy
      allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=).and_call_original
      allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_call_original
    end
    [ period.reload, item.reload ]
  end

  def accepted_response(link, payload = link.payload)
    metadata = payload.fetch("metadata").deep_dup
    metadata["payment_effective_on"] = payload["payment_effective_on"] if payload.key?("payment_effective_on")
    if payload["status"] == "payment_cancelled"
      metadata["original_payment_effective_on_known"] = payload["payment_effective_on"].present?
      metadata["original_payment_effective_on"] = payload["payment_effective_on"].presence
    end
    { "entry_processing" => payload.except("obligation_correction").merge("metadata" => metadata),
      "obligation_correction" => { "binding_id" => link.id.to_s, "request_digest" => link.request_digest, "command" => link.payload.fetch("obligation_correction") },
      "integration" => { "protocol" => "shimizu_time_payroll", "protocol_version" => "1.0", "source_type" => "fixture_time",
        "source_instance_id" => instance_id, "capabilities" => source.source_capabilities } }
  end

  def accept_link(item)
    link = item.time_tracking_financial_correction_links.first!
    link.accept!(accepted_response(link))
    link.aire_payroll_entry_acknowledgements.first!.mark_delivered!(at: Time.current)
    link
  end

  it "retains authoritative copy ancestry and sends the actual new period instead of the original import period" do
    period, item = build_correction
    link = item.time_tracking_financial_correction_links.first!
    expect(item.financial_correction_origin_item_id).to eq(original_item.id)
    expect(link.payload.values_at("external_pay_period_id", "external_payroll_item_id")).to eq([ period.id.to_s, item.id.to_s ])
    expect(link.payload.dig("obligation_correction", "predecessor", "payment_voided_event_id")).to eq(link.aire_payroll_entry_acknowledgements.first!.delivery_dependencies.map { |id| AirePayrollEntryAcknowledgement.find(id).event_id }.first)
    expect(original_import.reload.pay_period_id).to eq(original_period.id)
  end

  it "uses the actual prior corrected owner and its corrected inputs in a second generation" do
    period, item = build_correction(bonus: 25)
    expect(item.bonus).to eq(25)
    expect(original_item.bonus).not_to eq(item.bonus)
    first_link = accept_link(item)
    PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Correct the next unpaid payroll detail")
    next_period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct the next unpaid payroll detail")
    next_item = next_period.payroll_items.find_by!(employee: employee)
    expect(next_item.financial_correction_origin_item_id).to eq(item.id)
    expect(next_item.bonus).to eq(25)
    expect(next_item.bonus).to eq(item.bonus)
    expect(next_item.custom_deductions).to eq(item.custom_deductions)
    PayrollCalculator.for(employee, next_item).calculate
    next_item.save!
    next_period.update!(status: "calculated")
    life = PayPeriodLifecycleService.new(pay_period: next_period, actor: actor)
    life.approve!
    life.commit!
    second = next_item.time_tracking_financial_correction_links.first!
    expect(second.predecessor_payroll_item_id).to eq(item.id)
    expect(second.payload.dig("obligation_correction", "financial_assertion", "voided_pay_period_id")).to eq(period.id.to_s)
    expect(first_link.reload.payload.dig("obligation_correction", "successor", "external_pay_period_id")).to eq(period.id.to_s)
  end

  it "does not require financial amounts to equal the original Source-covered payroll" do
    period, item = build_correction(commit: false)
    PayrollBonusInput.manual!(item, 25)
    item.save!
    PayrollCalculator.for(employee, item).calculate
    item.save!
    PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit!
    expect(item.reload.gross_pay).to eq(125)
    expect(item.time_tracking_financial_correction_links.first!.payload["regular_hours"]).to eq("4.0")
  end

  it "fails unsupported or changed-hour commit before posting money, assigning checks or recording a commit event" do
    period, item = build_correction(commit: false)
    source.update!(source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2])
    saved = item.attributes
    expect { PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Test connection/)
    expect(period.reload.status).to eq("approved")
    expect(period.payroll_liability_postings).to be_empty
    expect(item.reload.attributes).to eq(saved)
    source.update!(source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1])
    item.update!(hours_worked: 3)
    expect { PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /REG and OT/)
    expect(period.reload.status).to eq("approved")
  end

  it "retries the same committed intent without reapplying money and rejects a stale preview" do
    period, item = build_correction(legacy: true)
    expect(item.financial_correction_origin_item_id).to be_nil
    expect(item.time_tracking_financial_correction_links).to be_empty
    expect { item.mark_package_prepared!(user: actor) }.to raise_error(ArgumentError, /Source/)
    expect { item.mark_printed!(user: actor) }.to raise_error(ArgumentError, /Source/)
    service = TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor)
    preview = service.preview
    before = [ item.attributes, EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes, period.payroll_liability_postings.map(&:attributes) ]
    expect { service.confirm!(expected_digest: "stale") }.to raise_error(TimeTracking::FinancialCorrectionService::Error, /review/)
    2.times { service.confirm!(expected_digest: preview.fetch(:expected_digest)) }
    expect(item.time_tracking_financial_correction_links.count).to eq(1)
    expect(item.aire_payroll_entry_acknowledgements.where(status: "committed").count).to eq(1)
    expect([ item.reload.attributes, EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes, period.payroll_liability_postings.map(&:attributes) ]).to eq(before)
  end

  it "holds an unverified linked successor that already has payment evidence" do
    period, item = build_correction
    item.check_events.insert_all!([ { event_type: "delivered", check_number: item.check_number, payroll_item_id: item.id, effective_on: PayrollBusinessClock.today, created_at: Time.current, updated_at: Time.current } ])
    expect { TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor).preview }.to raise_error(TimeTracking::FinancialCorrectionService::Error, /payment evidence/)
  end

  it "allows accepted-link preparation, delivery and reprint readiness after ordinary issuance" do
    _period, item = build_correction
    accept_link(item)
    expect { item.mark_package_prepared!(user: actor) }.not_to raise_error
    allow(CheckPackagePreparation).to receive(:current_for?).with(item).and_return(true)
    item.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today, delivery_method: "hand_delivery", attestation: true, evidence_reference: "Synthetic delivery")
    expect { item.ensure_financial_source_payment_ready! }.not_to raise_error
    expect { item.mark_printed!(user: actor) }.not_to raise_error
    expect(item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_issued").wire_payload["external_pay_period_id"]).to eq(item.pay_period_id.to_s)
  end




  it "keeps one saved intent reviewable when initial enqueue and explicit retry both fail" do
    period, item = build_correction(legacy: true)
    service = TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor)
    digest = service.preview.fetch(:expected_digest)
    saved = item.attributes
    allow(AirePayrollEntryStatusSyncJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, "Synthetic queue unavailable")
    2.times { expect(service.confirm!(expected_digest: digest).fetch(:status)).to eq("failed") }
    expect(item.time_tracking_financial_correction_links.count).to eq(1)
    expect(item.aire_payroll_entry_acknowledgements.where(status: "committed").count).to eq(1)
    expect(item.reload.attributes).to eq(saved)
  end

  it "holds missing legacy frozen allocations before creating a new link or a package" do
    period, item = build_correction(legacy: true)
    allocation.delete
    expect { TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor).preview }
      .to raise_error(TimeTracking::FinancialCorrectionService::Error, /allocation is missing/)
    expect { item.mark_package_prepared!(user: actor) }.to raise_error(ArgumentError, /allocation is missing/)
    expect(item.time_tracking_financial_correction_links).to be_empty
  end

  it "does not automatically connect legacy payroll that already has confirmed bank evidence" do
    period, item = build_correction(legacy: true)
    DirectDepositPaymentConfirmation.insert_all!([ { payroll_item_id: item.id, user_id: actor.id,
      settled_on: PayrollBusinessClock.today, bank_reference: "SYNTHETIC-ALREADY-SETTLED", created_at: Time.current, updated_at: Time.current } ])
    expect { TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor).preview }
      .to raise_error(TimeTracking::FinancialCorrectionService::Error, /payment evidence/)
    expect(item.time_tracking_financial_correction_links).to be_empty
  end

  it "keeps a failed delivery pending and retries its identical durable command through the normal job" do
    _period, item = build_correction
    link = item.time_tracking_financial_correction_links.first!
    ack = link.aire_payroll_entry_acknowledgements.first!
    ack.delivery_dependencies.each { |id| AirePayrollEntryAcknowledgement.find(id).mark_delivered!(at: Time.current) }
    saved = ack.wire_payload.deep_dup
    response = accepted_response(link)
    invalid = response.deep_dup
    invalid["obligation_correction"]["request_digest"] = "wrong"
    allow_any_instance_of(TimeTracking::Client).to receive(:request_json).and_return(invalid)
    expect { AirePayrollEntryStatusSyncJob.new.perform(ack.id) }.to raise_error(TimeTracking::Client::Error)
    expect(link.reload).not_to be_accepted
    expect(ack.reload.delivered_at).to be_nil
    expect(ack.last_error).to be_present
    expect(ack.wire_payload).to eq(saved)
    allow_any_instance_of(TimeTracking::Client).to receive(:request_json).and_return(response)
    AirePayrollEntryStatusSyncJob.new.perform(ack.id)
    expect(link.reload).to be_accepted
    expect(ack.reload.delivered_at).to be_present
    expect(ack.wire_payload).to eq(saved)
    expect(item.time_tracking_financial_correction_links.count).to eq(1)
  end

  it "records a confirmed bank callback only after the exact Source binding is accepted" do
    _period, item = build_correction
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    expect { item.create_direct_deposit_payment_confirmation!(user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "SYNTHETIC-BANK") }.to raise_error(ArgumentError, /Source/)
    accept_link(item)
    item.create_direct_deposit_payment_confirmation!(user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "SYNTHETIC-BANK")
    expect { item.ensure_financial_source_payment_ready! }.not_to raise_error
    ack = item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_issued")
    expect(ack.wire_payload).to include("payment_method" => "direct_deposit", "payment_reference" => "SYNTHETIC-BANK",
      "external_pay_period_id" => item.pay_period_id.to_s, "payment_effective_on" => PayrollBusinessClock.today.iso8601)
  end

  it "protects immutable lineage, atomic acceptance fields and TRUNCATE at the database boundary" do
    _period, item = build_correction
    link = item.time_tracking_financial_correction_links.first!
    expect { ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute("UPDATE time_tracking_financial_correction_links SET accepted_at=NOW() WHERE id=#{link.id}") } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute("TRUNCATE time_tracking_financial_correction_links CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { ApplicationRecord.transaction(requires_new: true) { link.update_columns(payload: {}) } }.to raise_error(ActiveRecord::StatementInvalid)
    ack = link.aire_payroll_entry_acknowledgements.first!
    expect { ApplicationRecord.transaction(requires_new: true) { ack.update_columns(payroll_item_id: original_item.id) } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { ApplicationRecord.transaction(requires_new: true) { ack.delete } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute("TRUNCATE aire_payroll_entry_acknowledgements") } }.to raise_error(ActiveRecord::StatementInvalid)
    expect(link.reload.accepted_at).to be_nil
    expect(link.accepted_receipt).to eq({})
  end


  it "keeps a newly added unsourced employee usable in a correction without inventing ancestry" do
    period, _item = build_correction(commit: false)
    worker = create(:employee, :salary, company: company, pay_rate: 26_000)
    salary = create(:payroll_item, employee: worker, company: company, pay_period: period, employment_type: "salary", pay_rate: 26_000)
    PayrollCalculator.for(worker, salary).calculate
    salary.save!
    PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit!
    expect { salary.ensure_financial_source_payment_ready! }.not_to raise_error
    expect(salary.time_tracking_financial_correction_links).to be_empty
  end

  it "does not hold a separate unsourced salary item when the Source-backed item needs connection review" do
    worker = create(:employee, :salary, company: company, pay_rate: 26_000)
    old_salary = create(:payroll_item, employee: worker, company: company, pay_period: original_period, employment_type: "salary", pay_rate: 26_000)
    PayrollCalculator.for(worker, old_salary).calculate
    old_salary.save!
    worker.ytd_totals_for(2026).add_payroll_item!(old_salary)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2026).add_payroll_item!(old_salary)
    company.assign_check_numbers!([ old_salary ])
    period, item = build_correction
    salary = period.payroll_items.find_by!(employee: worker)
    source.update!(source_capabilities: [])
    expect { salary.ensure_financial_source_payment_ready! }.not_to raise_error
    expect { item.ensure_financial_source_payment_ready! }.to raise_error(ArgumentError)
  end
  it "records one financial-link reversal after retained check retirement and reissue" do
    period, item = build_correction
    link = accept_link(item)
    item.mark_package_prepared!(user: actor)
    item.void!(user: actor, reason: "Retire the damaged corrected check")
    old_number = item.check_number
    item.update!(voided: false, voided_at: nil, void_reason: nil, check_number: company.next_check_number!,
      reprint_of_check_number: old_number, check_prepared_at: nil, check_prepared_source_updated_at: nil)
    item.mark_package_prepared!(user: actor)
    event = PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Explicit whole corrected payroll reversal")
    expect(link.aire_payroll_entry_acknowledgements.where(status: "payment_voided").count).to eq(1)
    TimeTracking::FinancialCorrectionService.record_instrumentless_void!(pay_period: period.reload, void_event: event)
    expect(link.aire_payroll_entry_acknowledgements.where(status: "payment_voided").count).to eq(1)
  end
end

RSpec.describe "Concurrent correction Source catch-up", :postgres_concurrency do
  self.use_transactional_tests = false
  include_context "exact source correction fixtures"
  let(:original_payment_state) { "unprepared" }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1], identity_verified_at: Time.current)
  end

  # A disposable namespace in the already owned test DB keeps append-only evidence
  # intact and avoids deleting its immutable rows for concurrency-test cleanup.
  around do |example|
    @correction_workers = []
    connection = ApplicationRecord.connection
    original_search_path = connection.schema_search_path
    schema = "financial_correction_race_#{SecureRandom.hex(8)}"
    connection.execute("CREATE SCHEMA #{schema}")
    connection.schema_search_path = schema
    connection.schema_cache.clear!
    load Rails.root.join("db/schema.rb")
    example.run
  ensure
    # A timed join can leave a transaction alive. DDL cleanup must never race it:
    # retain the namespace if bounded cleanup still cannot finish the workers.
    cleanup = join_correction_workers(timeout: 60)
    connection.schema_search_path = original_search_path
    connection.schema_cache.clear!
    if cleanup[:unfinished].any?
      raise Timeout::Error, "Correction workers did not stop; retained schema #{schema}. #{correction_worker_details(cleanup[:unfinished])}"
    end
    connection.execute("DROP SCHEMA IF EXISTS #{schema} CASCADE") if schema
  end

  def join_correction_workers(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    errors = []
    @correction_workers.each do |worker|
      remaining = [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
      worker.join(remaining)
    rescue StandardError => e
      # Joining an errored worker raises. Still join every other worker before
      # cleanup; the example re-raises the worker's actual failure below.
      errors << e
    end
    { unfinished: @correction_workers.select(&:alive?), errors: errors }
  end

  def correction_worker_details(workers)
    workers.map { |worker| "backend=#{worker[:backend_pid] || 'not connected'} status=#{worker.status} #{Array(worker.backtrace).first(3).join(' | ')}" }.join("; ")
  end

  it "records one durable actual-target intent when two operators confirm the same reviewed legacy correction" do
    allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=)
    allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_return([])
    PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: "Correct saved payroll")
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct saved payroll")
    item = period.payroll_items.first!
    PayrollCalculator.for(employee, item).calculate
    item.save!
    period.update!(status: "calculated")
    life = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    life.approve!
    life.commit!
    allow_any_instance_of(PayrollItem).to receive(:financial_correction_origin_item=).and_call_original
    allow_any_instance_of(TimeTracking::FinancialCorrectionService).to receive(:record_commit!).and_call_original
    digest = TimeTracking::FinancialCorrectionService.new(pay_period: period, actor: actor).preview.fetch(:expected_digest)
    before = [ item.reload.attributes, period.payroll_liability_postings.map(&:attributes), EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes ]
    schema = ApplicationRecord.connection.schema_search_path
    ready = Queue.new
    start = Queue.new
    2.times do
      @correction_workers << Thread.new do
        ApplicationRecord.connection_pool.with_connection do |connection|
          previous = connection.schema_search_path
          previous_timeout = connection.select_value("SHOW statement_timeout")
          connection.schema_search_path = schema
          # Genuine SQL waits remain bounded and surface as worker failures,
          # rather than leaving a transaction alive during schema teardown.
          connection.execute("SET statement_timeout TO '60s'")
          Thread.current[:backend_pid] = connection.select_value("SELECT pg_backend_pid()")
          ready << true
          start.pop
          TimeTracking::FinancialCorrectionService.new(pay_period: PayPeriod.find(period.id), actor: User.find(actor.id)).confirm!(expected_digest: digest)
        ensure
          connection.schema_search_path = previous
          connection.execute("SET statement_timeout TO #{connection.quote(previous_timeout)}") if previous_timeout
        end
      end
    end
    require "timeout"
    Timeout.timeout(30) { 2.times { ready.pop } }
    2.times { start << true }
    completed = join_correction_workers(timeout: 120)
    raise completed[:errors].first if completed[:errors].any?
    expect(completed[:unfinished]).to be_empty, "Concurrent confirmation timed out. #{correction_worker_details(completed[:unfinished])}"
    expect(@correction_workers.map(&:value).map { |result| result.fetch(:status) }).to eq(%w[pending pending])
    expect(item.time_tracking_financial_correction_links.count).to eq(1)
    expect(item.aire_payroll_entry_acknowledgements.where(status: "committed").count).to eq(1)
    expect([ item.reload.attributes, period.payroll_liability_postings.map(&:attributes), EmployeeYtdTotal.find_by!(employee: employee, year: 2026).attributes ]).to eq(before)
  ensure
    2.times { start << true } if start
  end
end
