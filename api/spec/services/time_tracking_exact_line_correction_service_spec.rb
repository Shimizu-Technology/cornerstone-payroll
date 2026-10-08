# frozen_string_literal: true

require 'rails_helper'
require "timeout"

RSpec.describe TimeTracking::ExactLineCorrectionService do
  let!(:tax_table) { create(:tax_table, tax_year: 2026) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:actor) { create(:user, company: company, role: 'admin') }
  let(:employee) { create(:employee, company: company, pay_rate: 25, pay_frequency: 'biweekly', filing_status: 'single', allowances: 0) }
  let(:instance_id) { SecureRandom.uuid }
  let(:user_uuid) { SecureRandom.uuid }
  let!(:rate) { create(:employee_wage_rate, employee: employee, rate: 25, label: 'Flight Hours', is_primary: true) }
  let!(:workweek) { CompanyWorkweek.create!(company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: 'Pacific/Guam', effective_on: '2026-01-01', confirmation_status: 'confirmed', confirmed_by: actor, notes: 'Verified test workweek', confirmed_at: Time.current) }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: 'custom',
      remote_source_identifier: 'fixture_time', expected_source_instance_id: instance_id,
      source_protocol: 'shimizu_time_payroll', source_protocol_version: '1.0',
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2], identity_verified_at: Time.current)
  end
  let(:original_period) { create(:pay_period, company: company, start_date: '2026-10-01', end_date: '2026-10-15', pay_date: '2026-10-30') }
  let(:next_period) { create(:pay_period, company: company, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15') }
  let(:original_item) do
    item = create(:payroll_item, company: company, employee: employee, pay_period: original_period,
      pay_rate: 25, hours_worked: 4, overtime_hours: 0, holiday_hours: 0, pto_hours: 0)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    original_period.update!(status: 'committed', committed_at: Time.current)
    employee.ytd_totals_for(2026).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2026).add_payroll_item!(item)
    company.assign_check_numbers!([ item ])
    item.reload
  end
  let(:original_import) { make_import(original_period, 4, 'current', 'ORIGINAL', status: 'applied') }
  let(:next_import) { make_import(next_period, -1, 'correction', 'NEXT') }
  let!(:allocation) do
    source
    item = original_item
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: '42', source_user_uuid: user_uuid)
    TimeTracking::EntryAllocationRecorder.new(time_tracking_import: original_import, payroll_item: item,
      source_employee: original_import.raw_payload['employees'].first).call
    original_import.time_tracking_entry_allocations.first
  end
  let(:service) { described_class.new(import: next_import, actor: actor, source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500') }

  before do
    allow_any_instance_of(TimeTracking::Client).to receive(:payroll_batch) { |_client, batch_id:| batch_id == 'NEXT' ? next_import.raw_payload : original_import.raw_payload }
  end

  def make_import(period, hours, kind, batch_id, status: 'previewed', mixed: false, entry_version: nil)
    raw = build_aire_batch_payload(batch_id: batch_id, start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
    raw['source'] = 'fixture_time'
    raw['integration'] = { 'protocol' => 'shimizu_time_payroll', 'protocol_version' => '1.0',
      'source_instance_id' => instance_id, 'source_type' => 'fixture_time', 'capabilities' => %w[finalized_batch_v2 exact_line_receipts_v2] }
    raw['exclusions'] = []
    row = raw['employees'].first
    row['source_user_uuid'] = user_uuid
    line = row['adjustments'].first
    line['source_user_uuid'] = user_uuid
    line['source_kind'] = kind
    line['source_time_entry_version'] = entry_version || (kind == 'current' ? 0 : 1)
    %w[total_hours regular_hours].each { |key| row[key] = hours; line[key] = hours; raw['summary'][key] = hours }
    raw['summary']['exclusion_count'] = 0
    raw['summary']['current_count'] = kind == 'current' ? 1 : 0
    raw['summary']['correction_count'] = kind == 'correction' ? 1 : 0
    raw['issues']['pending_approval_count'] = 0
    raw['issues']['negative_adjustment_count'] = hours.negative? ? 1 : 0
    if mixed
      2.times do |index|
        worker = create(:employee, company: company, pay_rate: 25)
        create(:employee_wage_rate, employee: worker, rate: 25, label: "Flight Hours", is_primary: true)
        uuid = SecureRandom.uuid
        id = (50 + index).to_s
        TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: worker, source_user_id: id, source_user_uuid: uuid)
        positive = row.deep_dup
        positive["source_user_id"] = id
        positive["source_user_uuid"] = uuid
        positive["email"] = worker.email
        positive["display_name"] = worker.full_name
        positive_line = positive["adjustments"].first
        positive_line["source_time_entry_id"] = (200 + index).to_s
        positive_line["source_user_uuid"] = uuid
        positive_line["source_kind"] = "carryover"
        %w[total_hours regular_hours].each { |key| positive[key] = 4; positive_line[key] = 4 }
        raw["employees"] << positive
      end
      raw["summary"].merge!("employee_count" => 3, "adjustment_count" => 3, "carryover_count" => 2, "total_hours" => 7, "regular_hours" => 7)
    end
    raw['export']['checksum'] = TimeTracking::CanonicalPayload.checksum(raw.except('export'))
    processed = TimeTracking::BatchImportPreviewService.new(pay_period: period, source: source).send(:process, raw, workweek: workweek)
    create(:time_tracking_import, pay_period: period, time_tracking_source: source, status: status,
      external_batch_id: batch_id, external_batch_checksum: raw['export']['checksum'],
      source_payload_hash: raw['export']['checksum'], contract_version: '2.0', source_cutoff_at: Time.iso8601(raw['cutoff_at']),
      raw_payload: raw, processed_payload: processed)
  end

  def confirm(preview = service.preview, **options)
    service.confirm!(**{ preview_token: preview[:preview_token], reason: 'Source hours corrected by operator', acknowledge_accounting_only: true }.merge(options))
  end

  it 'commits once, preserves original and frozen proof, and reports accounting coverage separately from paid' do
    frozen_original = original_item.attributes
    frozen_batch = next_import.raw_payload.deep_dup
    preview = service.preview
    expect(preview[:deltas][:gross_pay]).to eq(-25.0)
    disposition = confirm(preview)
    item = disposition.corrective_payroll_item
    expect(item.gross_pay).to eq(-25)
    expect(item.check_number).to be_nil
    expect(item.pay_period).to be_committed
    expect(confirm(preview).id).to eq(disposition.id)
    expect(PayrollItem.where(correction_for_payroll_item_id: original_item.id).count).to eq(1)
    expect(original_item.reload.attributes).to eq(frozen_original)
    expect(next_import.reload.raw_payload).to eq(frozen_batch)
    payload = disposition.time_tracking_correction_receipt.payload
    expect(payload['external_pay_period_id']).to eq(item.pay_period_id.to_s)
    expect(payload['metadata']).to include('accounting_only' => true)
    expect(payload.keys.grep(/payment/)).to be_empty
    expect(TimeTracking::CorrectionCoverage.new(next_import).ordinary_employees).to be_empty
    expect(TimeTracking::CorrectionCoverage.new(next_import).verify_complete!).to eq(true)
    summary = TimeTracking::AllocationStatusSummary.call(next_import)
    expect(summary[:line_count]).to eq(1)
    expect(summary[:accounting_corrections][:total_hours]).to eq(-1)
    expect(summary[:paid][:line_count]).to eq(0)
  end

  it 'preserves ordinary negative guards until explicit accounting disposition' do
    result = TimeTracking::ApplyImportService.new(import: next_import, mappings: [], applied_by: actor,
      acknowledge_negative_adjustments: true, negative_adjustment_note: 'Reviewed exact correction').call
    expect(result[:errors]).not_to be_empty
    expect(next_import.reload.status).to eq('previewed')
    confirm
    result = TimeTracking::ApplyImportService.new(import: next_import, mappings: [], applied_by: actor).call
    expect(result[:errors]).to eq([])
    expect(next_import.reload.status).to eq('applied')
    expect(next_period.payroll_items.count).to eq(0)
  end

  context "concurrent exact-line confirmations", :postgres_concurrency do
    self.use_transactional_tests = false

    # This example commits fixtures so separate PostgreSQL connections can see
    # them. Capture IDs before setup and remove only that fixture delta after
    # joining all owned workers, including append-only audit and ledger rows.
    around do |example|
      connection = ApplicationRecord.connection
      raise "Concurrency fixtures require the test environment" unless Rails.env.test?
      tables = connection.tables.filter_map do |table|
        key = connection.primary_key(table)
        next unless key.is_a?(String) && !table.in?(%w[schema_migrations ar_internal_metadata])
        [ table, key, connection.select_values("SELECT #{connection.quote_column_name(key)} FROM #{connection.quote_table_name(table)}").to_set ]
      end
      example.run
    ensure
      connection.disable_referential_integrity do
        tables.each do |table, key, existing|
          current = connection.select_values("SELECT #{connection.quote_column_name(key)} FROM #{connection.quote_table_name(table)}")
          created = current.reject { |id| existing.include?(id) }
          next if created.empty?
          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE #{connection.quote_column_name(key)} IN (#{created.map { |id| connection.quote(id) }.join(',')})")
        end
      end
    end

    it "returns the same corrective item, disposition and outbox when two confirmations race" do
      preview = service.preview
      ready = Queue.new
      release = Queue.new
      outcomes = Queue.new
      workers = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            worker = described_class.new(import: TimeTrackingImport.find(next_import.id), actor: User.find(actor.id),
              source_user_id: "42", source_time_entry_id: "101", line_key: "7:2500")
            row = worker.confirm!(preview_token: preview[:preview_token], reason: "Verified concurrent source correction", acknowledge_accounting_only: true)
            outcomes << row.id
          rescue StandardError => error
            outcomes << error
          end
        end
      end
      2.times { ready.pop(timeout: 10) || raise(Timeout::Error, "Worker did not start") }
      2.times { release << true }
      workers.each { |thread| Timeout.timeout(20) { thread.join } }
      results = 2.times.map { outcomes.pop }
      expect(results).to all(be_a(Integer))
      expect(results.uniq.length).to eq(1)
      expect(PayrollItem.where(correction_for_payroll_item_id: original_item.id).count).to eq(1)
      expect(TimeTrackingCorrectionDisposition.where(time_tracking_import: next_import).count).to eq(1)
      expect(TimeTrackingCorrectionReceipt.where(time_tracking_correction_disposition_id: results.first).count).to eq(1)
      expect(original_item.reload.hours_worked).to eq(4)
    ensure
      workers&.each { |thread| Timeout.timeout(20) { thread.join } }
    end
  end

  context "source version proof" do
    let(:next_import) { make_import(next_period, -1, "correction", "NEXT", entry_version: 0) }

    it "rejects a frozen correction version that does not advance the original" do
      expect { service.preview }.to raise_error(ArgumentError, /version.*does not advance/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end
  end

  context "mixed batch" do
    let(:next_import) { make_import(next_period, -1, "correction", "NEXT", mixed: true) }

    it "accounts for all three frozen lines through disjoint correction and ordinary same-run allocations" do
      confirm
      expect(TimeTracking::CorrectionCoverage.new(next_import).processed_payload["rows"].size).to eq(2)
      result = TimeTracking::ApplyImportService.new(import: next_import, mappings: [], applied_by: actor).call
      expect(result[:errors]).to eq([])
      expect(result[:applied].size).to eq(2)
      expect(next_import.time_tracking_entry_allocations.count).to eq(2)
      expect(next_import.time_tracking_entry_allocations.sum(:regular_hours)).to eq(8)
      expect(TimeTracking::CorrectionCoverage.new(next_import).verify_complete!).to eq(true)
      expect(next_period.payroll_items.pluck(:hours_worked)).to eq([ 4, 4 ])
      expect(original_item.reload.hours_worked).to eq(4)
      expect(TimeTracking::AllocationStatusSummary.call(next_import)[:total_hours]).to eq(7)
      expect(TimeTracking::AllocationStatusSummary.call(next_import)[:paid][:line_count]).to eq(0)
      links = PayPeriodTimeTrackingSummary.call(next_period)[:linked_source_records].first[:correction_dispositions]
      expect(links.first).to include(original_pay_period_id: original_period.id, original_payroll_item_id: original_item.id,
        corrective_pay_period_id: TimeTrackingCorrectionDisposition.first.corrective_payroll_item.pay_period_id,
        accounting_only: true)
    end
  end

  it 'requires reason, acknowledgment and the same operator' do
    preview = service.preview
    expect { confirm(preview, reason: 'short') }.to raise_error(ArgumentError, /reason/)
    expect { confirm(preview, acknowledge_accounting_only: false) }.to raise_error(ArgumentError, /Acknowledge/)
    other = described_class.new(import: next_import, actor: create(:user, company: company), source_user_id: '42', source_time_entry_id: '101', line_key: '7:2500')
    expect { other.confirm!(preview_token: preview[:preview_token], reason: 'reviewed source correction', acknowledge_accounting_only: true) }.to raise_error(ArgumentError, /another operator/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it 'rejects stale history and rolls back financial correction if outbox creation fails' do
    preview = service.preview
    original_item.update_columns(correction_reason: 'changed since preview')
    expect { confirm(preview) }.to raise_error(ArgumentError, /history changed/)
    fresh = service.preview
    allow(TimeTrackingCorrectionReceipt).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
    expect { confirm(fresh) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(PayrollItem.where(correction_for_payroll_item_id: original_item.id).count).to eq(0)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it 'rejects changed source installation and remote frozen proof' do
    remote = next_import.raw_payload.deep_dup
    remote['employees'].first['adjustments'].first['source_time_entry_version'] = 2
    allow_any_instance_of(TimeTracking::Client).to receive(:payroll_batch).and_return(remote)
    expect { service.preview }.to raise_error(ArgumentError, /frozen source batch changed|checksum verification failed/)
    source.update!(expected_source_instance_id: SecureRandom.uuid)
    expect { service.preview }.to raise_error(ArgumentError, /installation identity changed/)
  end

  it 'rejects unmatched line keys, mixed rates and prior active corrections' do
    missing = described_class.new(import: next_import, actor: actor, source_user_id: '42', source_time_entry_id: '101', line_key: 'wrong')
    expect { missing.preview }.to raise_error(ArgumentError, /exact negative/)
    create(:employee_wage_rate, employee: employee, rate: 30)
    expect { service.preview }.to raise_error(ArgumentError, /rate or hours/)
    employee.employee_wage_rates.where.not(id: rate.id).delete_all
    IssueCorrectivePaycheckService.issue!(original_pay_period: original_period, employee: employee,
      corrected_inputs: { hours_worked: 3 }, pay_date: next_period.pay_date, reason: 'earlier correction')
    expect { service.preview }.to raise_error(ArgumentError, /existing corrective/)
  end

  it "rejects foreign operators and checksum tampering" do
    preview = service.preview
    stranger = create(:user, company: create(:company), role: "admin")
    foreign = described_class.new(import: next_import, actor: stranger, source_user_id: "42", source_time_entry_id: "101", line_key: "7:2500")
    expect { foreign.preview }.to raise_error(ArgumentError, /payroll access to this company/)
    next_import.update_columns(external_batch_checksum: "f" * 64)
    expect { confirm(preview) }.to raise_error(ArgumentError, /provenance/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "uses a durable immutable outbox after source failure and replays the same signed command" do
    preview = service.preview
    disposition = confirm(preview)
    receipt = disposition.time_tracking_correction_receipt
    allow_any_instance_of(TimeTracking::Client).to receive(:record_accounting_correction_event).and_raise(TimeTracking::Client::Error, "Temporary source outage")
    expect { TimeTrackingCorrectionReceiptJob.new.perform(receipt.id) }.to raise_error(TimeTracking::Client::Error)
    expect(receipt.reload.delivered_at).to be_nil
    expect(receipt.last_error).to eq("Temporary source outage")
    expect(confirm(preview).id).to eq(disposition.id)
    allow_any_instance_of(TimeTracking::Client).to receive(:record_accounting_correction_event).with(**receipt.payload.deep_symbolize_keys).and_return({})
    TimeTrackingCorrectionReceiptJob.new.perform(receipt.id)
    expect(receipt.reload.delivered_at).to be_present
    expect(receipt.last_error).to be_nil
    expect { disposition.update_columns(reason: "alter immutable proof") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    sql = "UPDATE time_tracking_correction_dispositions SET reason = 'alter immutable proof' WHERE id = #{Integer(disposition.id)}"
    expect { ApplicationRecord.connection.execute(sql) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'holds native voids after delivery so committed source accounting evidence cannot become stale' do
    disposition = confirm
    disposition.time_tracking_correction_receipt.update!(delivered_at: Time.current)
    item = disposition.corrective_payroll_item
    expect { PayPeriodCorrectionService.void!(pay_period: item.pay_period, actor: actor, reason: 'reviewing correction') }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /source receipt can be reversed together/)
    expect { PayPeriodCorrectionService.void!(pay_period: original_period, actor: actor, reason: 'reviewing correction') }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /source receipt can be reversed together/)
    expect { original_item.void!(user: actor, reason: 'reviewing correction') }.to raise_error(ArgumentError, /source receipt can be reversed together/)
    expect(item.reload).not_to be_voided
    expect(original_item.reload).not_to be_voided
    expect(original_item.check_events.where(event_type: 'voided')).not_to exist
  end
end
