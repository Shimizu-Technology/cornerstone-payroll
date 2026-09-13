# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckReconciliationEventService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company:, organization: company.organization, role: "accountant") }
  let(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let(:employee) { create(:employee, company:) }
  let(:payroll_item) do
    create(:payroll_item, :with_check, company:, pay_period: period, employee:, check_number: "8100", net_pay: 925)
  end

  def issue_employee_check!
    payroll_item.mark_printed!(user: actor)
    payroll_item.mark_delivered!(
      user: actor,
      delivered_on: "2026-08-20",
      delivery_method: "hand_delivery",
      attestation: true,
      evidence_reference: "Handoff log 22"
    )
  end

  def perform(attributes)
    described_class.new(company:, actor:, attributes: attributes).call
  end

  it "records clearing evidence and safely replays the same idempotency key" do
    issue_employee_check!
    attributes = {
      source_type: "payroll_item",
      source_id: payroll_item.id,
      event_type: "cleared",
      effective_on: "2026-08-24",
      evidence_type: "bank_statement",
      evidence_reference: "FHB August statement p. 3",
      idempotency_key: SecureRandom.uuid
    }

    first = nil
    expect { first = perform(attributes) }.to change(CheckReconciliationEvent, :count).by(1)
    expect { expect(perform(attributes)).to eq(first) }.not_to change(CheckReconciliationEvent, :count)
    expect(CheckReconciliationStatus.for(payroll_item.reload)).to eq("cleared")
  end

  it "rejects a reused idempotency key for a different action" do
    issue_employee_check!
    key = SecureRandom.uuid
    perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
      effective_on: "2026-08-24", evidence_type: "bank_portal",
      evidence_reference: "Transaction 123", idempotency_key: key
    )

    expect {
      perform(
        source_type: "payroll_item", source_id: payroll_item.id, event_type: "clearing_reversed",
        effective_on: "2026-08-25", reason: "Bank later rejected the item", idempotency_key: key
      )
    }.to raise_error(described_class::Error, /different reconciliation action/)
  end

  it "rejects a reused idempotency key when the evidence details differ" do
    issue_employee_check!
    key = SecureRandom.uuid
    perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
      effective_on: "2026-08-24", evidence_type: "bank_portal",
      evidence_reference: "Transaction 123", idempotency_key: key
    )

    expect {
      perform(
        source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
        effective_on: "2026-08-24", evidence_type: "bank_portal",
        evidence_reference: "Transaction 456", idempotency_key: key
      )
    }.to raise_error(described_class::Error, /different reconciliation action/)
  end

  it "preserves a correction as a new event instead of changing clearing evidence" do
    issue_employee_check!
    cleared = perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
      effective_on: "2026-08-24", evidence_type: "bank_statement",
      evidence_reference: "Statement item 44", idempotency_key: SecureRandom.uuid
    )

    reversed = perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "clearing_reversed",
      effective_on: "2026-08-25", reason: "Matched the wrong bank transaction", idempotency_key: SecureRandom.uuid
    )

    expect(reversed.id).not_to eq(cleared.id)
    expect(CheckReconciliationStatus.for(payroll_item.reload)).to eq("issued")
    expect { cleared.update!(reason: "rewrite") }.to raise_error(ActiveRecord::RecordNotSaved, /Failed to save/)
    expect {
      CheckReconciliationEvent.transaction(requires_new: true) do
        CheckReconciliationEvent.where(id: cleared.id).update_all(reason: "rewrite")
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { cleared.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed, /Failed to destroy/)
  end

  it "marks an issued check as replacement required and keeps the wage obligation issued" do
    issue_employee_check!

    perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "replacement_required",
      effective_on: "2026-08-22", reason: "Employee reported the issued check lost", idempotency_key: SecureRandom.uuid
    )

    expect(CheckReconciliationStatus.for(payroll_item.reload)).to eq("replacement_required")
    expect(payroll_item).not_to be_voided
  end

  it "does not allow replacement or clearing corrections to predate the state they describe" do
    issue_employee_check!
    expect {
      perform(
        source_type: "payroll_item", source_id: payroll_item.id, event_type: "replacement_required",
        effective_on: "2026-08-19", reason: "Employee reported the issued check lost",
        idempotency_key: SecureRandom.uuid
      )
    }.to raise_error(described_class::Error, /before the issue date/)

    perform(
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
      effective_on: "2026-08-24", evidence_type: "bank_statement",
      evidence_reference: "Statement item 50", idempotency_key: SecureRandom.uuid
    )
    expect {
      perform(
        source_type: "payroll_item", source_id: payroll_item.id, event_type: "clearing_reversed",
        effective_on: "2026-08-23", reason: "Matched the wrong bank transaction",
        idempotency_key: SecureRandom.uuid
      )
    }.to raise_error(described_class::Error, /before the cleared date/)
  end

  it "supports clearing a confirmed non-employee paper payment" do
    payment = create(:non_employee_check, :with_check_number, company:, pay_period: period,
      payment_period_type: "pay_period", payment_date: Date.new(2026, 8, 20))
    payment.mark_printed!
    payment.mark_paid!(actor:, payment_date: "2026-08-20")

    perform(
      source_type: "non_employee_check", source_id: payment.id, event_type: "cleared",
      effective_on: "2026-08-23", evidence_type: "bank_portal",
      evidence_reference: "FHB transaction 9001", idempotency_key: SecureRandom.uuid
    )

    expect(CheckReconciliationStatus.for(payment.reload)).to eq("cleared")
  end

  it "rejects clearing before issue, without evidence, or for another company" do
    issue_employee_check!
    common = {
      source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
      evidence_type: "bank_statement", evidence_reference: "Statement", idempotency_key: SecureRandom.uuid
    }
    expect { perform(common.merge(effective_on: "2026-08-19")) }
      .to raise_error(described_class::Error, /before the issue date/)
    expect { perform(common.merge(effective_on: "2026-08-24", evidence_reference: "", idempotency_key: SecureRandom.uuid)) }
      .to raise_error(described_class::Error, /Evidence reference/)

    foreign_item = create(:payroll_item, :with_check)
    expect {
      perform(common.merge(source_id: foreign_item.id, effective_on: "2026-08-24", idempotency_key: SecureRandom.uuid))
    }.to raise_error(described_class::Error, /Check not found/)
  end

  it "rejects future-dated reconciliation evidence" do
    issue_employee_check!

    expect {
      perform(
        source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
        effective_on: (PayrollBusinessClock.today + 1.day).iso8601, evidence_type: "bank_statement",
        evidence_reference: "Future statement", idempotency_key: SecureRandom.uuid
      )
    }.to raise_error(described_class::Error, /cannot be in the future/)
  end
end
