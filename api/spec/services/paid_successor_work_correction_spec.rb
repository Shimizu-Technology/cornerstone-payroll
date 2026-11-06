# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Exact work correction after accepted financial succession" do
  include_context "exact source correction fixtures"
  let(:original_payment_state) { "unprepared" }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "fixture_time",
      expected_source_instance_id: instance_id, source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: %w[finalized_batch_v2 exact_line_receipts_v2 payroll_obligation_correction_v1 payment_cancellation_v1], identity_verified_at: Time.current)
  end

  def build_successor(predecessor = original_period)
    PayPeriodCorrectionService.void!(pay_period: predecessor, actor: actor, reason: "Correct unpaid financial deductions")
    period = PayPeriodCorrectionService.create_correction_run!(source_pay_period: original_period.reload, actor: actor, reason: "Correct unpaid financial deductions")
    item = period.payroll_items.find_by!(employee: employee)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    period.update!(status: "calculated")
    lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    lifecycle.approve!
    lifecycle.commit!
    [ period.reload, item.reload ]
  end

  def accept_successor(item)
    item.time_tracking_financial_correction_links.each do |link|
      payload = link.payload
      response = { "entry_processing" => payload.except("obligation_correction"),
        "obligation_correction" => { "binding_id" => link.id.to_s, "request_digest" => link.request_digest, "command" => payload.fetch("obligation_correction") },
        "integration" => { "protocol" => source.source_protocol, "protocol_version" => source.source_protocol_version,
          "source_type" => source.remote_source_identifier, "source_instance_id" => instance_id, "capabilities" => source.source_capabilities } }
      link.accept!(response)
      link.aire_payroll_entry_acknowledgements.first!.mark_delivered!(at: Time.current)
    end
  end

  def issue_successor(item)
    item.mark_package_prepared!(user: actor)
    allow(CheckPackagePreparation).to receive(:current_for?).with(item).and_return(true)
    item.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today, delivery_method: "hand_delivery",
      attestation: true, evidence_reference: "Synthetic paid successor")
    item.reload
  end

  def paid_successor
    period, item = build_successor
    accept_successor(item)
    issue_successor(item)
    [ period, item ]
  end

  it "records once against the paid successor and preserves all settled checks, original work and ownership history" do
    period, current = paid_successor
    frozen = [ original_item.reload.attributes, original_period.reload.attributes, current.attributes,
      allocation.reload.attributes, original_import.reload.attributes,
      current.check_events.order(:id).map(&:attributes), current.time_tracking_financial_correction_links.map(&:attributes) ]
    preview = service.preview
    expect(preview).to include(original_pay_period_id: period.id, original_payroll_item_id: current.id,
      frozen_origin_pay_period_id: original_period.id, frozen_origin_payroll_item_id: original_item.id)
    expect(preview[:deltas]).to include(gross_pay: -25.0, social_security_tax: -1.55, medicare_tax: -0.36, net_pay: -23.09)
    disposition = confirm(preview)
    corrective = disposition.corrective_payroll_item
    expect(corrective).to have_attributes(correction_for_payroll_item_id: current.id, hours_worked: -1, gross_pay: -25, net_pay: -23.09, check_number: nil)
    expect(corrective.pay_period).to have_attributes(corrects_pay_period_id: period.id, status: "committed")
    expect(corrective.total_deductions).to eq(-1.91)
    expect(corrective.calculation_context_snapshot.dig("corrective_paycheck", "source_accounting_target", "target_payroll_item_id")).to eq(current.id)
    expect(disposition.original_allocation_id).to eq(allocation.id)
    expect(disposition.time_tracking_correction_receipt.payload["metadata"]).to include(
      "original_pay_period_id" => period.id.to_s, "original_payroll_item_id" => current.id.to_s)
    expect(disposition.time_tracking_correction_receipt.payload.keys.grep(/payment/)).to be_empty
    expect(confirm(preview).id).to eq(disposition.id)
    expect(TimeTrackingCorrectionDisposition.count).to eq(1)
    expect(TimeTrackingCorrectionReceipt.count).to eq(1)
    expect([ original_item.reload.attributes, original_period.reload.attributes, current.reload.attributes,
      allocation.reload.attributes, original_import.reload.attributes,
      current.check_events.order(:id).map(&:attributes), current.time_tracking_financial_correction_links.map(&:attributes) ]).to eq(frozen)
    expect(TimeTracking::CorrectionCoverage.new(next_import).presentation.first).to include(
      original_payroll_item_id: current.id, frozen_origin_payroll_item_id: original_item.id, verification_status: "verified")
    expect { current.void!(user: actor, reason: "Attempt unsafe paid target void") }.to raise_error(ArgumentError, /exact source accounting correction/)
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Attempt unsafe paid period void") }
      .to raise_error(PayPeriodCorrectionService::InvalidStateError, /exact source accounting correction/)
    result = TimeTracking::ApplyImportService.new(import: next_import, mappings: [], applied_by: actor).call
    expect(result[:errors]).to eq([])
    expect(next_import.reload.status).to eq("applied")
    expect(next_period.payroll_items).to be_empty
  end

  it "resolves the latest accepted owner across two financial generations" do
    first_period, first = build_successor
    accept_successor(first)
    second_period, second = build_successor(first_period)
    accept_successor(second)
    issue_successor(second)
    preview = service.preview
    expect(preview[:original_payroll_item_id]).to eq(second.id)
    expect(preview[:financial_successor_link_ids].size).to eq(2)
    expect(confirm(preview).corrective_payroll_item.pay_period.corrects_pay_period_id).to eq(second_period.id)
  end

  it "keeps the ordinary public corrective-paycheck guard closed for correction runs" do
    period, _current = paid_successor
    expect(period.can_issue_corrective_paycheck?).to be(false)
    expect { IssueCorrectivePaycheckService.issue!(original_pay_period: period, employee: employee,
      corrected_inputs: { hours_worked: 3 }, pay_date: next_period.pay_date, reason: "Unproven correction-run bypass") }
      .to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /regular committed/)
  end

  it "holds pending accepted ownership rather than falling back to the voided origin" do
    build_successor
    expect { service.preview }.to raise_error(ArgumentError, /pending Source confirmation/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds an accepted but unissued successor" do
    _period, current = build_successor
    accept_successor(current)
    expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds successor rate drift against the immutable frozen work owner" do
    _period, current = paid_successor
    current.update_columns(pay_rate: 26)
    expect { service.preview }.to raise_error(ArgumentError, /changed work, rate/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds changed current payment proof after review without posting money" do
    period, current = paid_successor
    preview = service.preview
    current.check_reconciliation_events.create!(company: company, pay_period: period, recorded_by: actor,
      event_type: "cleared", check_number: current.check_number, amount: current.net_pay,
      effective_on: PayrollBusinessClock.today, evidence_type: "bank_statement", idempotency_key: SecureRandom.uuid)
    expect { confirm(preview) }.to raise_error(ArgumentError, /history changed/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds current item drift after review and preserves the existing financial ledger" do
    _period, current = paid_successor
    preview = service.preview
    postings = PayrollLiabilityPosting.order(:id).map(&:attributes)
    current.update_columns(bonus: 1)
    expect { confirm(preview) }.to raise_error(ArgumentError, /component detail does not reconcile/)
    expect(PayrollLiabilityPosting.order(:id).map(&:attributes)).to eq(postings)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "rejects stale current-item proof without changing component-reconciliation inputs" do
    _period, current = paid_successor
    preview = service.preview
    postings = PayrollLiabilityPosting.order(:id).map(&:attributes)
    current.update_columns(correction_reason: "Synthetic proof annotation")
    expect(service.preview[:deltas]).to eq(preview[:deltas])
    expect { confirm(preview) }.to raise_error(ArgumentError, /Source or payroll history changed/)
    expect(PayrollLiabilityPosting.order(:id).map(&:attributes)).to eq(postings)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "rejects a forged trusted-target argument instead of accepting an API-style hash" do
    period, _current = paid_successor
    expect { IssueCorrectivePaycheckService.new(original_pay_period: period, employee: employee,
      corrected_inputs: { hours_worked: 3, overtime_hours: 0 }, source_accounting_target: { verified: true }).preview }
      .to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /verified payment target/)
  end
  it "holds a changed Source installation after review" do
    paid_successor
    preview = service.preview
    source.update!(expected_source_instance_id: SecureRandom.uuid)
    expect { confirm(preview) }.to raise_error(ArgumentError, /installation|identity|changed/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds a foreign financial target even when its link points at the right frozen allocation" do
    _period, current = paid_successor
    current.update_columns(employee_id: create(:employee, company: company).id)
    expect { service.preview }.to raise_error(ArgumentError, /ancestry|ownership|proof/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "holds another disconnected successor instead of choosing the newest row" do
    _period, current = paid_successor
    old = current.time_tracking_financial_correction_links.first!
    foreign = create(:payroll_item, company: company, employee: employee, pay_period: create(:pay_period, company: company))
    payload = old.payload.deep_dup
    successor = create(:payroll_item, company: company, employee: employee, pay_period: create(:pay_period, company: company))
    payload["external_pay_period_id"] = successor.pay_period_id.to_s
    payload["external_payroll_item_id"] = successor.id.to_s
    payload["obligation_correction"]["successor"]["external_pay_period_id"] = successor.pay_period_id.to_s
    payload["obligation_correction"]["successor"]["external_payroll_item_id"] = successor.id.to_s
    payload["event_id"] = SecureRandom.uuid
    payload["obligation_correction"]["command_id"] = SecureRandom.uuid
    payload["obligation_correction"]["predecessor"]["external_payroll_item_id"] = foreign.id.to_s
    TimeTrackingFinancialCorrectionLink.create!(original_allocation: allocation, predecessor_payroll_item: foreign,
      payroll_item: successor, command_id: payload.dig("obligation_correction", "command_id"), event_id: payload["event_id"],
      payload: payload, request_digest: TimeTracking::CanonicalPayload.checksum(payload))
    expect { service.preview }.to raise_error(ArgumentError, /disconnected|foreign/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "keeps the database uniqueness guard for ambiguous successors of the same predecessor" do
    _period, current = paid_successor
    link = current.time_tracking_financial_correction_links.first!
    duplicate = link.dup
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:original_allocation_id]).to be_present
  end

  context "a complete daily union with only one accepted successor line" do
    let(:original_regular_hours) { 10 }
    let(:original_import) do
      make_import(original_period, 4, "current", "ORIGINAL", status: "applied", daily_lines: [
        { source_time_entry_id: "101", total_hours: 4, regular_hours: 4, overtime_hours: 0 },
        { source_time_entry_id: "102", line_key: "7:2500:day2", original_work_date: "2026-10-06", total_hours: 6, regular_hours: 6, overtime_hours: 0 }
      ])
    end

    it "requires acceptance of the whole union before resolving any negative line" do
      _period, current = build_successor
      first = current.time_tracking_financial_correction_links.first!
      allow(current).to receive(:time_tracking_financial_correction_links).and_return([ first ])
      accept_successor(current)
      expect { service.preview }.to raise_error(ArgumentError, /pending Source confirmation/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end
  end

  [ [ "source_time_entry_version", 0 ], [ "source_category_id", "8" ] ].each do |field, value|
    it "holds successor correction #{field} drift" do
      paid_successor
      raw = next_import.raw_payload.deep_dup
      raw["employees"].first["adjustments"].first[field] = value
      raw["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(raw.except("export"))
      next_import.update_columns(raw_payload: raw, external_batch_checksum: raw["export"]["checksum"], source_payload_hash: raw["export"]["checksum"])
      expect { service.preview }.to raise_error(ArgumentError, /version|category|identity/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end
  end

  it "keeps bank-confirmed financial succession verifiable after consume and replay" do
    _period, current = build_successor
    accept_successor(current)
    current.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    confirmation = current.create_direct_deposit_payment_confirmation!(user: actor, settled_on: PayrollBusinessClock.today,
      bank_reference: "SYNTHETIC-CURRENT-PAID-BANK")
    frozen = confirmation.attributes
    preview = service.preview
    disposition = confirm(preview)
    expect(disposition.verified!).to eq(disposition)
    expect(confirm(preview).id).to eq(disposition.id)
    expect(confirmation.reload.attributes).to eq(frozen)
    expect(current.reload.net_pay).to eq(92.35)
    expect(disposition.corrective_payroll_item.net_pay).to eq(-23.09)
    expect(disposition.corrective_payroll_item.direct_deposit_payment_confirmation).to be_nil
  end

  [ "unconfirmed", "foreign_actor", "future_date", "missing_reference" ].each do |state|
    it "holds #{state} existing bank evidence on a successor" do
      _period, current = build_successor
      accept_successor(current)
      current.update!(payment_delivery_method: "direct_deposit", check_number: nil)
      unless state == "unconfirmed"
        user = state == "foreign_actor" ? create(:user) : actor
        DirectDepositPaymentConfirmation.insert_all!([ { payroll_item_id: current.id, user_id: user.id,
          settled_on: state == "future_date" ? PayrollBusinessClock.today + 1.day : PayrollBusinessClock.today,
          bank_reference: state == "missing_reference" ? "" : "SYNTHETIC-BANK-EVIDENCE",
          created_at: Time.current, updated_at: Time.current } ])
      end
      expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
      expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    end
  end

  it "holds foreign actor delivery proof even with an accepted financial chain" do
    _period, current = paid_successor
    CheckEvent.insert_all!([ { payroll_item_id: current.id, user_id: create(:user).id,
      event_type: "delivered", check_number: current.check_number, effective_on: PayrollBusinessClock.today,
      created_at: Time.current + 1.second, updated_at: Time.current + 1.second } ])
    expect { service.preview }.to raise_error(ArgumentError, /Original payment not verified/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "preserves a posted successor disposition when native clearing history appends" do
    period, current = paid_successor
    disposition = confirm
    current.check_reconciliation_events.create!(company: company, pay_period: period, recorded_by: actor,
      event_type: "cleared", check_number: current.check_number, amount: current.net_pay,
      effective_on: PayrollBusinessClock.today, evidence_type: "bank_statement", idempotency_key: SecureRandom.uuid)
    expect(disposition.reload.verified!).to eq(disposition)
    current.check_reconciliation_events.create!(company: company, pay_period: period, recorded_by: actor,
      event_type: "clearing_reversed", check_number: current.check_number, amount: current.net_pay,
      effective_on: PayrollBusinessClock.today, evidence_type: "accountant_review", idempotency_key: SecureRandom.uuid)
    expect(disposition.reload.verified!).to eq(disposition)
    expect(current.reload.net_pay).to eq(92.35)
    expect(disposition.corrective_payroll_item.net_pay).to eq(-23.09)
  end

  [ "tax sync", "pay date correction" ].each do |operation|
    it "keeps posted successor evidence verifiable after supported #{operation} and retries its same receipt" do
      period, current = paid_successor
      current.update!(check_date: period.pay_date) if operation == "pay date correction"
      disposition = confirm
      receipt = disposition.time_tracking_correction_receipt
      retained = [ disposition.attributes, receipt.payload.deep_dup, current.check_events.order(:id).map(&:attributes) ]
      if operation == "tax sync"
        allow(PayrollTaxSyncService).to receive(:configured?).and_return(true)
        allow_any_instance_of(PayrollTaxSyncService).to receive(:post_to_cst).and_return(Struct.new(:code, :body).new("204", ""))
        PayrollTaxSyncJob.new.perform(period.id)
        expect(period.reload.tax_sync_status).to eq("synced")
      else
        PayPeriodPayDateCorrectionService.call(pay_period: period, actor: actor,
          new_pay_date: period.pay_date + 1.day, reason: "Correct the clerical synthetic pay date")
        expect(current.reload.check_date).to eq(period.reload.pay_date)
      end
      expect(disposition.reload.verified!).to eq(disposition)
      expect(TimeTracking::CorrectionCoverage.new(next_import).verify_complete!).to eq(true)
      receipt.update!(last_error: "Synthetic Source outage", enqueued_at: Time.current)
      expect(receipt.dispatch!(retry_failed: true)).to be(true)
      allow_any_instance_of(TimeTracking::Client).to receive(:record_accounting_correction_event).with(**receipt.payload.deep_symbolize_keys).and_return({})
      TimeTrackingCorrectionReceiptJob.new.perform(receipt.id)
      expect(receipt.reload.delivered_at).to be_present
      expect([ disposition.reload.attributes, receipt.payload, current.check_events.order(:id).map(&:attributes) ]).to eq(retained)
      expect(current.reload.net_pay).to eq(92.35)
      expect(disposition.corrective_payroll_item.net_pay).to eq(-23.09)
    end
  end


  it "verifies complete legacy target evidence without rewriting saved rows and rejects omitted material fields" do
    period, current = paid_successor
    resolver = TimeTracking::PaidCorrectionTarget.new(allocation: allocation, source: source,
      line: next_import.raw_payload["employees"].first["adjustments"].first)
    legacy = resolver.resolve.fetch(:evidence).deep_dup
    legacy["version"] = 1
    legacy.delete("target_tax_year")
    legacy["target"] = JSON.parse(JSON.generate(TimeTracking::CanonicalPayload.canonicalize(current.attributes)))
    legacy["target_period"] = JSON.parse(JSON.generate(TimeTracking::CanonicalPayload.canonicalize(period.attributes)))
    retained = legacy.deep_dup
    allow(PayrollTaxSyncService).to receive(:configured?).and_return(true)
    allow_any_instance_of(PayrollTaxSyncService).to receive(:post_to_cst).and_return(Struct.new(:code, :body).new("204", ""))
    PayrollTaxSyncJob.new.perform(period.id)
    expect(resolver.matches_saved_evidence?(legacy)).to be(true)
    expect(legacy).to eq(retained)
    legacy["target"].delete("withholding_tax")
    expect(resolver.matches_saved_evidence?(legacy)).to be(false)
  end

  { "net_pay" => 90, "withholding_tax" => 2, "social_security_tax" => 5, "medicare_tax" => 1,
    "employer_social_security_tax" => 5, "employer_medicare_tax" => 1, "additional_withholding_override" => 3,
    "withholding_tax_override" => 4, "calculation_context_snapshot" => { "tampered" => true },
    "tax_rule_snapshot" => { "tampered" => true }, "timekeeping_context_snapshot" => { "tampered" => true } }.each do |field, value|
    it "rejects posted material target #{field} drift" do
      _period, current = paid_successor
      disposition = confirm
      current.update_columns(field => value)
      expect { disposition.reload.verified! }.to raise_error(ArgumentError, /evidence no longer matches/)
      expect(TimeTracking::CorrectionCoverage.new(next_import).presentation.first[:verification_status]).to eq("needs_review")
    end
  end


  it "keeps a cross-year date change and unknown target evidence versions fail closed" do
    period, _current = paid_successor
    disposition = confirm
    resolver = TimeTracking::PaidCorrectionTarget.new(allocation: allocation, source: source,
      line: next_import.raw_payload["employees"].first["adjustments"].first)
    stored = disposition.corrective_payroll_item.calculation_context_snapshot.dig("corrective_paycheck", "source_accounting_target")
    [ 99, "1", 1.0, nil ].each do |version|
      expect(resolver.matches_saved_evidence?(stored.merge("version" => version))).to be(false)
    end
    expect { PayPeriodPayDateCorrectionService.call(pay_period: period, actor: actor,
      new_pay_date: Date.new(2027, 1, 15), reason: "Synthetic cross-year change") }.to raise_error(PayPeriodPayDateCorrectionService::Error, /same tax year/)
    period.update_columns(pay_date: Date.new(2027, 1, 15))
    expect { disposition.reload.verified! }.to raise_error(ArgumentError, /evidence no longer matches/)
  end
end
