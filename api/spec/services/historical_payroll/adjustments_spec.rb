# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Historical payroll adjustment ledger" do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:employee) { create(:employee, company: company, first_name: "Ada", last_name: "Ledger") }
  let!(:batch) do
    create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current, locked_by: actor)
  end
  let!(:period) do
    HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: company,
      external_key: "adjustment-period",
      source_label: "QuickBooks payroll",
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 20),
      paycheck_count: 1,
      totals: { "gross_pay" => "1000.0", "net_pay" => "800.0" }
    )
  end
  let!(:worker) do
    create(:historical_worker, historical_import_batch: batch, company: company, employee: employee,
                               mapping_status: "exact_match")
  end
  let!(:paycheck) do
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: company,
      employee: employee,
      external_key: "adjustment-paycheck",
      source_employee_name: employee.full_name,
      source_row_number: 1,
      source_status: "paid",
      reconciliation_status: "matched",
      period_start: period.start_date,
      period_end: period.end_date,
      pay_date: period.pay_date,
      gross_pay: 1_000,
      adjusted_gross: 1_000,
      employee_taxes: 150,
      federal_income_tax: 100,
      social_security_tax: 40,
      medicare_tax: 10,
      after_tax_deductions: 50,
      net_pay: 800,
      total_payroll_cost: 1_000
    )
  end

  def adjustment_input(key: "ledger-adjustment-1", gross_pay: 100)
    {
      kind: "correction",
      effective_pay_date: paycheck.pay_date.iso8601,
      reason: "Correct retained source classification",
      external_reference: "CASE-2026-04",
      idempotency_key: key,
      gross_pay: gross_pay,
      federal_income_tax: 10,
      social_security_tax: 6.20,
      medicare_tax: 1.45,
      after_tax_deductions: 5
    }
  end

  def create_adjustment(input = adjustment_input)
    preview = HistoricalPayroll::AdjustmentPreviewService.new(paycheck: paycheck, actor: actor, attributes: input).call
    expect(preview).to be_ready
    HistoricalPayroll::AdjustmentCreateService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: input,
      acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
      preview_digest: preview.digest
    ).call
  end

  it "previews and appends a signed correction without changing the source snapshot" do
    original = paycheck.attributes
    preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck, actor: actor, attributes: adjustment_input
    ).call

    expect(preview).to be_ready
    expect(preview.attributes).to include(
      employee_taxes: 17.65.to_d,
      adjusted_gross: 100.to_d,
      net_pay: 77.35.to_d,
      total_payroll_cost: 100.to_d
    )
    adjustment = create_adjustment

    expect(paycheck.reload.attributes).to eq(original)
    expect(adjustment).to be_persisted
    expect(adjustment.employee_tax_breakdown).to eq([ { "label" => "Historical correction", "amount" => "17.65" } ])
    expect(HistoricalPayroll::Ledger.new(batch: batch).adjusted_totals.fetch(:gross_pay)).to eq(1_100.to_d)
    expect(AuditLog.where(record_type: "historical_paycheck_adjustments", record_id: adjustment.id)).to exist
  end

  it "is idempotent and rejects a changed preview or acknowledgement" do
    input = adjustment_input
    preview = HistoricalPayroll::AdjustmentPreviewService.new(paycheck: paycheck, actor: actor, attributes: input).call
    service = HistoricalPayroll::AdjustmentCreateService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: input,
      acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
      preview_digest: preview.digest
    )

    first = service.call
    expect(service.call).to eq(first)
    expect(HistoricalPaycheckAdjustment.count).to eq(1)

    expect do
      HistoricalPayroll::AdjustmentCreateService.new(
        paycheck: paycheck, actor: actor, attributes: adjustment_input(key: "wrong-ack"),
        acknowledgement: "wrong", preview_digest: preview.digest
      ).call
    end.to raise_error(ArgumentError, /RECORD HISTORICAL ADJUSTMENT/)
  end

  it "does not reuse idempotency keys across source paychecks or reversal targets" do
    first = create_adjustment
    second_paycheck = paycheck.dup
    second_paycheck.assign_attributes(external_key: "adjustment-paycheck-2", source_row_number: 2)
    second_paycheck.save!
    second_input = adjustment_input.merge(idempotency_key: first.idempotency_key)
    second_preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: second_paycheck, actor: actor, attributes: second_input
    ).call

    expect do
      HistoricalPayroll::AdjustmentCreateService.new(
        paycheck: second_paycheck,
        actor: actor,
        attributes: second_input,
        acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
        preview_digest: second_preview.digest
      ).call
    end.to raise_error(ArgumentError, /another historical paycheck/)

    other = create_adjustment(adjustment_input(key: "other-adjustment"))
    expect do
      HistoricalPayroll::AdjustmentReversalService.new(
        adjustment: first,
        actor: actor,
        reason: "Wrong idempotency target",
        idempotency_key: other.idempotency_key,
        acknowledgement: HistoricalPayroll::AdjustmentReversalService::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ArgumentError, /another historical adjustment/)
    expect(first.reload.reversal).to be_nil
  end

  it "rejects corrections that would reduce retained totals below zero" do
    preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: adjustment_input(gross_pay: -1_001).merge(net_pay: -801)
    ).call

    expect(preview).not_to be_ready
    expect(preview.errors).to include(
      "Gross pay cannot reduce the historical paycheck below zero",
      "Net pay cannot reduce the historical paycheck below zero"
    )
  end

  it "validates malformed breakdown entries instead of accepting or crashing on them" do
    adjustment = HistoricalPaycheckAdjustment.new(
      company: company,
      historical_paycheck: paycheck,
      created_by: actor,
      kind: "correction",
      effective_pay_date: paycheck.pay_date,
      filing_year: paycheck.pay_date.year,
      filing_quarter: 1,
      reason: "Malformed retained evidence",
      idempotency_key: "malformed-breakdown",
      earnings_breakdown: [ "not-an-entry" ]
    )

    expect(adjustment).not_to be_valid
    expect(adjustment.errors[:earnings_breakdown]).to include("entry 1 requires a label", "entry 1 requires a numeric amount")
  end

  it "voids the remaining value and restores it only through an exact inverse reversal" do
    correction = create_adjustment
    void_input = {
      kind: "void",
      effective_pay_date: paycheck.pay_date.iso8601,
      reason: "Void the retained paycheck after external confirmation",
      idempotency_key: "ledger-void"
    }
    preview = HistoricalPayroll::AdjustmentPreviewService.new(paycheck: paycheck, actor: actor, attributes: void_input).call
    void = HistoricalPayroll::AdjustmentCreateService.new(
      paycheck: paycheck, actor: actor, attributes: void_input,
      acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
      preview_digest: preview.digest
    ).call

    expect(HistoricalPayroll::Ledger.new(batch: batch).adjusted_totals.fetch(:gross_pay)).to eq(0.to_d)
    reversal = HistoricalPayroll::AdjustmentReversalService.new(
      adjustment: void,
      actor: actor,
      reason: "Reinstate after corrected evidence",
      idempotency_key: "ledger-reversal",
      acknowledgement: HistoricalPayroll::AdjustmentReversalService::ACKNOWLEDGEMENT
    ).call
    expect(reversal.reverses_adjustment).to eq(void)
    expect(HistoricalPayroll::Ledger.new(batch: batch).adjusted_totals.fetch(:gross_pay)).to eq(1_100.to_d)
    expect(HistoricalPayroll::AdjustmentReversalService.new(
      adjustment: void, actor: actor, reason: "retry", idempotency_key: "other",
      acknowledgement: HistoricalPayroll::AdjustmentReversalService::ACKNOWLEDGEMENT
    ).call).to eq(reversal)
    expect do
      HistoricalPayroll::AdjustmentReversalService.new(
        adjustment: reversal, actor: actor, reason: "Invalid reversal chain", idempotency_key: "reverse-reversal",
        acknowledgement: HistoricalPayroll::AdjustmentReversalService::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ActiveRecord::RecordInvalid, /cannot itself be a reversal/)
    expect(correction.update(reason: "rewrite")).to be(false)
    expect(correction.destroy).to be(false)
  end

  it "records append-only filing and downstream events" do
    adjustment = create_adjustment
    event = HistoricalPayroll::AdjustmentEventService.new(
      adjustment: adjustment,
      actor: actor,
      event_type: "filing_amendment_required",
      note: "Quarterly return review required"
    ).call

    expect(adjustment.filing_review_state).to eq("amendment_required")
    expect(event.update(note: "rewrite")).to be(false)
    expect(event.destroy).to be(false)

    HistoricalPayroll::AdjustmentEventService.new(
      adjustment: adjustment,
      actor: actor,
      event_type: "filing_amendment_filed_external"
    ).call
    expect(adjustment.filing_review_state).to eq("amendment_filed_external")
  end

  it "requires YTD activation events to reference a bridge from the same import" do
    adjustment = create_adjustment
    missing_bridge = HistoricalPaycheckAdjustmentEvent.new(
      company: company,
      historical_paycheck_adjustment: adjustment,
      created_by: actor,
      event_type: "ytd_revision_activated"
    )
    expect(missing_bridge).not_to be_valid
    expect(missing_bridge.errors[:historical_ytd_bridge]).to include(/is required/)

    other_batch = create(:historical_import_batch, company: company)
    other_bootstrap = create(:historical_client_bootstrap, company: company, historical_import_batch: other_batch)
    other_bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: other_batch,
      historical_client_bootstrap: other_bootstrap,
      created_by: actor,
      status: "previewed",
      revision: 1,
      plan_digest: Digest::SHA256.hexdigest("other-import-plan"),
      preview_summary: {
        "through_period_end" => "2026-03-14",
        "through_pay_date" => "2026-03-20"
      }
    )
    mismatched_bridge = missing_bridge.dup
    mismatched_bridge.historical_ytd_bridge = other_bridge

    expect(mismatched_bridge).not_to be_valid
    expect(mismatched_bridge.errors[:historical_ytd_bridge]).to include(/adjustment's historical import/)
  end

  it "rolls back a ledger event when its audit record cannot be written" do
    adjustment = create_adjustment
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)

    expect do
      HistoricalPayroll::AdjustmentEventService.new(
        adjustment: adjustment,
        actor: actor,
        event_type: "filing_reviewed_no_amendment"
      ).call
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(adjustment.events.reload).to be_empty
  end

  it "rejects unlocked history, cross-tenant actors, and invalid effective dates" do
    batch.update_column(:status, "applied")
    result = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck, actor: actor, attributes: adjustment_input
    ).call
    expect(result.errors.join(" ")).to match(/locked history/)

    other_company = create(:company)
    other_actor = create(:user, company: other_company, organization: other_company.organization, role: "admin")
    batch.update_column(:status, "locked")
    expect do
      HistoricalPayroll::AdjustmentCreateService.new(
        paycheck: paycheck, actor: other_actor, attributes: adjustment_input,
        acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
        preview_digest: "wrong"
      ).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
  end

  it "keeps archive-only unlinked history outside the employee adjustment ledger" do
    paycheck.update_column(:employee_id, nil)

    preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: adjustment_input
    ).call

    expect(preview).not_to be_ready
    expect(preview.errors).to include("Historical paycheck must be linked to an employee")
  end
end
