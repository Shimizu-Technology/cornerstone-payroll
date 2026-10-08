# frozen_string_literal: true

require 'rails_helper'
require "timeout"

RSpec.describe TimeTracking::ExactLineCorrectionService do
  include_context "exact source correction fixtures"

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

  %w[unissued prepared voided_payment direct_deposit_unconfirmed].each do |payment_state|
    context "an original #{payment_state} payment" do
      let(:original_payment_state) { payment_state }

      it "rejects negative accounting before money changes because original payment is unverified" do
        original = original_item.attributes
        expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
        expect(PayrollItem.where(correction_for_payroll_item_id: original_item.id)).not_to exist
        expect(TimeTrackingCorrectionDisposition.count).to eq(0)
        expect(original_item.reload.attributes).to eq(original)
      end
    end
  end

  context "a bank-confirmed original direct deposit" do
    let(:original_payment_state) { "direct_deposit_confirmed" }

    it "permits the accounting-only negative adjustment without creating a cash instrument" do
      disposition = confirm
      expect(disposition.corrective_payroll_item.gross_pay).to eq(-25)
      expect(disposition.corrective_payroll_item.check_number).to be_nil
      expect(original_item.reload.direct_deposit_payment_confirmation.bank_reference).to eq("SYNTHETIC-BANK-CONFIRMED")
      expect(disposition.time_tracking_correction_receipt.payload.keys.grep(/payment/)).to be_empty
    end
  end

  it "rejects zero-net original records instead of inventing a cash payment basis" do
    original_item.update_columns(net_pay: 0)
    expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "rejects replaced instrument history even if an older delivery event remains" do
    original_item.check_events.create!(user: actor, event_type: "replaced", check_number: original_item.check_number)
    expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "rejects an original payment evidence head that changed after preview" do
    preview = service.preview
    original_item.check_reconciliation_events.create!(company: company, pay_period: original_period, recorded_by: actor,
      event_type: "cleared", check_number: original_item.check_number, amount: original_item.net_pay,
      effective_on: PayrollBusinessClock.today, evidence_type: "bank_statement", idempotency_key: SecureRandom.uuid)
    expect { confirm(preview) }.to raise_error(ArgumentError, /history changed/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  context "a paycheck with several verified daily allocations" do
    let(:original_regular_hours) { 10 }
    let(:original_import) do
      make_import(original_period, 4, "current", "ORIGINAL", status: "applied", daily_lines: [
        { source_time_entry_id: "101", total_hours: 4, regular_hours: 4, overtime_hours: 0 },
        { source_time_entry_id: "102", line_key: "7:2500:day2", original_work_date: "2026-10-06", total_hours: 6, regular_hours: 6, overtime_hours: 0 }
      ])
    end

    it "corrects the target day against whole-paycheck totals and preserves every original daily line and other payroll item" do
      other_employee = create(:employee, company: company)
      other_item = create(:payroll_item, company: company, employee: other_employee, pay_period: original_period)
      frozen_original = original_item.attributes
      frozen_other = other_item.attributes
      frozen_allocations = original_item.time_tracking_entry_allocations.order(:id).map(&:attributes)
      frozen_batch = original_import.raw_payload.deep_dup
      preview = service.preview
      expect(preview[:original][:gross_pay]).to eq(250)
      expect(preview[:corrected][:gross_pay]).to eq(225)
      disposition = confirm(preview)
      expect(disposition.original_allocation_id).to eq(allocation.id)
      expect(disposition.corrective_payroll_item.hours_worked).to eq(-1)
      expect(disposition.corrective_payroll_item.gross_pay).to eq(-25)
      expect(original_item.reload.attributes).to eq(frozen_original)
      expect(other_item.reload.attributes).to eq(frozen_other)
      expect(original_item.time_tracking_entry_allocations.order(:id).map(&:attributes)).to eq(frozen_allocations)
      expect(original_import.reload.raw_payload).to eq(frozen_batch)
      expect(TimeTracking::CorrectionCoverage.new(next_import).verify_complete!).to eq(true)
    end

    context "overtime on several days" do
      let(:original_regular_hours) { 16 }
      let(:original_overtime_hours) { 3 }
      let(:original_import) do
        make_import(original_period, 10, "current", "ORIGINAL", status: "applied", daily_lines: [
          { source_time_entry_id: "101", total_hours: 10, regular_hours: 8, overtime_hours: 2 },
          { source_time_entry_id: "102", line_key: "7:2500:day2", original_work_date: "2026-10-06", total_hours: 9, regular_hours: 8, overtime_hours: 1 }
        ])
      end
      let(:next_import) do
        make_import(next_period, -1, "correction", "NEXT", daily_lines: [
          { source_time_entry_id: "101", total_hours: -1, regular_hours: 0, overtime_hours: -1 }
        ])
      end

      it "reduces only the target day's overtime using the historical whole-item overtime total" do
        preview = service.preview
        expect(preview[:original][:gross_pay]).to eq(512.5)
        expect(preview[:corrected][:gross_pay]).to eq(475)
        disposition = confirm(preview)
        expect(disposition.corrective_payroll_item.hours_worked).to eq(0)
        expect(disposition.corrective_payroll_item.overtime_hours).to eq(-1)
        expect(disposition.corrective_payroll_item.gross_pay).to eq(-37.5)
        expect(original_item.reload.overtime_hours).to eq(3)
        expect(original_item.time_tracking_entry_allocations.sum(:overtime_hours)).to eq(3)
      end

      it "rejects a delta that consumes overtime allocated to another day" do
        next_import.update_columns(raw_payload: next_import.raw_payload)
        changed = next_import.raw_payload.deep_dup
        entry = changed["employees"].first["adjustments"].first
        entry["total_hours"] = entry["overtime_hours"] = -3
        changed["employees"].first["total_hours"] = changed["employees"].first["overtime_hours"] = -3
        changed["summary"]["total_hours"] = changed["summary"]["overtime_hours"] = -3
        changed["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(changed.except("export"))
        next_import.update_columns(raw_payload: changed, source_payload_hash: changed["export"]["checksum"], external_batch_checksum: changed["export"]["checksum"])
        expect { service.preview }.to raise_error(ArgumentError, /original.*line.*hours/)
      end
    end

    it "accepts a display-name-only category rename with unchanged stable earning identity" do
      replacement = make_import(next_period, -1, "correction", "RENAMED", category_name: "Flight time renamed")
      allow_any_instance_of(TimeTracking::Client).to receive(:payroll_batch).and_return(replacement.raw_payload)
      renamed_service = described_class.new(import: replacement, actor: actor, source_user_id: "42", source_time_entry_id: "101", line_key: "7:2500")
      preview = renamed_service.preview
      expect(preview[:deltas][:gross_pay]).to eq(-25)
      result = renamed_service.confirm!(preview_token: preview[:preview_token], reason: "Verified renamed category identity", acknowledge_accounting_only: true)
      expect(result.corrective_payroll_item.gross_pay).to eq(-25)
      expect(original_item.time_tracking_entry_allocations.count).to eq(2)
    end

    context "one persisted historical earning row" do
      let(:original_wage_rate_hours) do
        [ { "employee_wage_rate_id" => rate.id, "rate" => 25, "regular_hours" => 10, "overtime_hours" => 0,
          "holiday_hours" => 0, "pto_hours" => 0, "label" => "Flight Hours", "active" => true, "is_primary" => true } ]
      end

      it "preserves the single-rate earning proof while correcting one day" do
        original = original_item.attributes
        preview = service.preview
        expect(preview[:original][:gross_pay]).to eq(250)
        expect(preview[:corrected][:gross_pay]).to eq(225)
        disposition = confirm(preview)
        expect(disposition.corrective_payroll_item.gross_pay).to eq(-25)
        expect(original_item.reload.attributes).to eq(original)
      end
    end

    context "mixed original source earning identities" do
      let(:original_import) do
        make_import(original_period, 4, "current", "ORIGINAL", status: "applied", daily_lines: [
          { source_time_entry_id: "101", total_hours: 4, regular_hours: 4, overtime_hours: 0 },
          { source_time_entry_id: "102", line_key: "other-category", original_work_date: "2026-10-06", total_hours: 6,
            regular_hours: 6, overtime_hours: 0, source_category_id: "8", category: { id: 8, key: "other_earning", name: "Other" } }
        ])
      end

      it "rejects a paycheck whose original daily union spans earning categories" do
        expect { service.preview }.to raise_error(ArgumentError, /one earning\/rate/)
        expect(TimeTrackingCorrectionDisposition.count).to eq(0)
      end
    end

    it "rejects a foreign user identity injected into another original daily allocation" do
      second = original_item.time_tracking_entry_allocations.where.not(id: allocation.id).first
      ApplicationRecord.connection.execute("UPDATE time_tracking_entry_allocations SET source_user_uuid = '#{SecureRandom.uuid}' WHERE id = #{Integer(second.id)}")
      expect { service.preview }.to raise_error(ArgumentError, /Original allocation coverage/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end

    it "rejects original daily sums that no longer equal the posted paycheck inputs" do
      original_item.update_columns(hours_worked: 11)
      expect { service.preview }.to raise_error(ArgumentError, /sum to the original paycheck/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end

    it "rejects incomplete original allocation coverage" do
      second = original_item.time_tracking_entry_allocations.where.not(id: allocation.id).first
      ApplicationRecord.connection.execute("DELETE FROM time_tracking_entry_allocations WHERE id = #{Integer(second.id)}")
      expect { service.preview }.to raise_error(ArgumentError, /original.*allocation.*coverage|original.*allocation.*union/i)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end

    it "binds every original allocation in the reviewed digest" do
      preview = service.preview
      second = original_item.time_tracking_entry_allocations.where.not(id: allocation.id).first
      ApplicationRecord.connection.execute("UPDATE time_tracking_entry_allocations SET updated_at = updated_at + interval '1 second' WHERE id = #{Integer(second.id)}")
      expect { confirm(preview) }.to raise_error(ArgumentError, /history changed/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end
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

  it "holds supported replacement attention and financial replacement while allowing normal clearing" do
    disposition = confirm
    receipt = disposition.time_tracking_correction_receipt
    receipt.update!(delivered_at: Time.current)
    original = original_item.reload.attributes
    ytd = employee.ytd_totals_for(2026).attributes
    old_checks = original_item.check_events.order(:id).map(&:attributes)
    original_event_count = CheckReconciliationEvent.count
    attrs = { source_type: "payroll_item", source_id: original_item.id, event_type: "replacement_required",
      effective_on: PayrollBusinessClock.today.iso8601, reason: "Synthetic requested replacement",
      idempotency_key: SecureRandom.uuid }
    expect { CheckReconciliationEventService.new(company: company, actor: actor, attributes: attrs).call }
      .to raise_error(CheckReconciliationEventService::Error, /accounting correction/)
    expect(CheckReconciliationEvent.count).to eq(original_event_count)
    expect { ReplaceCheckService.preview(payroll_item: original_item, corrected_inputs: { hours_worked: 3 }) }
      .to raise_error(ReplaceCheckService::InvalidStateError, /accounting correction/)
    expect { ReplaceCheckService.replace!(payroll_item: original_item, corrected_inputs: { hours_worked: 3 },
      reason: "Synthetic requested replacement", actor: actor) }.to raise_error(ReplaceCheckService::InvalidStateError, /accounting correction/)
    replacement = ReplaceCheckService.new(payroll_item: original_item, corrected_inputs: { hours_worked: 3 },
      reason: "Synthetic previously reviewed replacement", actor: actor)
    # Model a replacement that passed its unlocked preview before the source
    # accounting posting; the locked guard must still hold financial mutation.
    allow(replacement).to receive(:validate_for_replace!).and_return(nil)
    expect { replacement.replace! }.to raise_error(ReplaceCheckService::InvalidStateError, /accounting correction/)
    expect(original_item.reload.attributes).to eq(original)
    expect(employee.ytd_totals_for(2026).reload.attributes).to eq(ytd)
    expect(original_item.check_events.order(:id).map(&:attributes)).to eq(old_checks)
    CheckReconciliationEventService.new(company: company, actor: actor, attributes: attrs.merge(event_type: "cleared",
      evidence_type: "bank_statement", evidence_reference: "Synthetic clearing evidence", idempotency_key: SecureRandom.uuid)).call
    expect(CheckReconciliationStatus.for(original_item.reload)).to eq("cleared")
    expect(disposition.reload.verified!).to eq(disposition)
    expect(receipt.reload.delivered_at).to be_present
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
    expect(PayrollPaymentMethodEligibility.new(original_item.reload).call[:reason]).to match(/accounting correction/)
    expect { PayrollPaymentMethodService.new(payroll_item: original_item, method: "direct_deposit", actor: actor,
      reason: "Synthetic requested payment retirement", confirm_not_paid: true, retire_existing_check: true,
      confirm_check_cancelled: true, cancellation_evidence_reference: "Synthetic cancellation request",
      expected_check_number: original_item.check_number).call }.to raise_error(PayrollPaymentMethodService::Error, /accounting correction/)
    expect(original_item.reload.effective_payment_delivery_method).to eq("paper_check")
    expect(original_item.check_events.where(event_type: "voided")).not_to exist
  end
end
