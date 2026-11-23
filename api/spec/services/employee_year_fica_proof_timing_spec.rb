# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeYearFicaContext do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:recovery) { PayrollFicaLegacyRecovery.new(company: company, year: 2024) }

  def calculate(status)
    period = create(:pay_period, company: company, status: status)
    item = period.payroll_items.build(company: company, employee: employee, employment_type: "hourly",
      pay_rate: 15, hours_worked: 0, bonus: 1000)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item
  end

  def context_for(item)
    described_class.new(employee: employee, year: 2024, excluding_pay_period_id: item.pay_period_id)
  end

  def append_reviewed_proof(item, evidence, at:)
    row = described_class.ledger_rows(PayrollItem.where(id: item.id)).sole
    PayrollItemFicaBasisProof.create!(payroll_item: item, company: company, created_by: actor,
      tax_year: 2024, plan_digest: "0" * 64, review_reference: "Synthetic proof time fixture", created_at: at,
      evidence: evidence.merge("row_digest" => FicaBasisEvidence.row_digest(row), "dependency_through_id" => row.id))
  end

  [ true, false ].each do |dated|
    it "retains the proof already captured and excludes the later proof with #{dated ? 'a' : 'no'} calculation timestamp" do
      first = calculate("committed")
      first.update_columns(tax_rule_snapshot: {}, social_security_taxable_tips: nil)
      plan = recovery.inventory
      recovery.apply!(actor: actor, review_reference: "Reviewed first proof timing fixture", expected_digest: plan.fetch(:plan_digest))
      first_proof_at = first.fica_basis_proof.created_at

      second = calculate("committed")
      second.update_columns(social_security_taxable_tips: nil)
      pending = calculate("calculated")
      # Keep the proof dates on either side of calculation. Item updates
      # after approval are deliberately newer than both proof timestamps.
      timestamp = first_proof_at + 1.second if dated
      pending.pay_period.update_columns(calculated_at: timestamp)
      saved = pending.tax_rule_snapshot.fetch("annual_fica_context")
      review = PayrollReview::CalculationSnapshot.new(pay_period: pending.pay_period)
      checksum = review.call.fetch(:checksum)

      append_reviewed_proof(second, first.fica_basis_proof.evidence, at: first_proof_at + 2.seconds)
      pending.update_columns(updated_at: first_proof_at + 3.seconds)
      current_context = context_for(pending)
      expect(current_context.snapshot).not_to eq(saved)
      expect(current_context.snapshot_for(pending)).to eq(saved)
      expect(review.call.fetch(:checksum)).to eq(checksum)
      if dated
        pending.tax_rule_snapshot["annual_fica_context"] = current_context.snapshot
        expect { current_context.snapshot_for(pending) }.to raise_error(described_class::UnreconciledLedgerError, /Recalculate/)
        pending.reload
      end

      lifecycle = PayPeriodLifecycleService.new(pay_period: pending.pay_period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      expect(pending.pay_period.reload).to be_committed
    end
  end
end
