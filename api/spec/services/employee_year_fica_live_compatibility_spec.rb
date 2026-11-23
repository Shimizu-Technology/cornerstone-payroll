# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeYearFicaContext do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:actor) { create(:user, company: company, role: "admin") }

  def calculate(status)
    period = create(:pay_period, company: company, status: status)
    item = period.payroll_items.build(company: company, employee: employee, employment_type: "hourly",
      pay_rate: 15, hours_worked: 0, bonus: 1000)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item
  end

  def main_snapshot(legacy)
    row = legacy.attributes.slice(*described_class::FINGERPRINT_FIELDS)
    row["legacy_basis_evidence"] = legacy.tax_rule_snapshot["annual_fica_context"]
    row["captured_fica_rules"] = legacy.tax_rule_snapshot.slice("tax_year", *FicaBasisEvidence::RULE_FIELDS).compact
    proof = legacy.fica_basis_proof
    row["reviewed_legacy_basis_evidence"] = proof.evidence if proof
    digest = Digest::SHA256.hexdigest(JSON.generate([ 3, 2024, employee.id, [ row ], nil ]))
    { "version" => 3, "year" => 2024, "employee_id" => employee.id, "fingerprint" => digest }
  end

  it "keeps main's live fingerprint, snapshot and snapshot_for bytes before and after a proof" do
    legacy = calculate("committed")
    legacy.update_columns(tax_rule_snapshot: {}, social_security_taxable_tips: nil)
    pending = create(:payroll_item, company: company, employee: employee, pay_period: create(:pay_period, :calculated, company: company))
    expected_before = main_snapshot(legacy)
    recovery = PayrollFicaLegacyRecovery.new(company: company, year: 2024)
    plan = recovery.inventory

    expect(recovery.apply!(actor: actor, review_reference: "Reviewed live compatibility fixture",
      expected_digest: plan.fetch(:plan_digest))).to include(applied_proofs: 1)

    expected_after = main_snapshot(legacy.reload)
    expect(expected_after).not_to eq(expected_before)
    # Load the old projected rows independently of live proof APIs to check
    # the pre-proof serializer after apply as well.
    row = described_class.ledger_rows(PayrollItem.where(id: legacy.id)).sole
    without_proof = PayrollItem.instantiate(row.attributes.merge("recorded_legacy_fica_proof" => nil))
    [ [ without_proof, expected_before ], [ row, expected_after ] ].each do |ledger_row, expected|
      context = described_class.new(employee: employee, year: 2024, rows: [ ledger_row ], opening_balance: nil)
      pending.tax_rule_snapshot = { "annual_fica_context" => expected_before }
      expect(context.fingerprint).to eq(expected.fetch("fingerprint"))
      expect(JSON.generate(context.snapshot)).to eq(JSON.generate(expected))
      expect(JSON.generate(context.snapshot_for(pending))).to eq(JSON.generate(expected))
    end
  end

  it "replays 26 committed legacy rows with quadratic work" do
    26.times { calculate("committed") }
    items = PayrollItem.where(employee: employee).order(:id).to_a
    items.each_with_index do |item, index|
      prior = described_class.ledger_rows(PayrollItem.where(id: items.take(index).map(&:id))).order(:id).to_a
      snapshot = described_class.new(employee: employee, year: 2024, rows: prior, opening_balance: nil).snapshot
      item.update_columns(social_security_taxable_tips: nil, tax_rule_snapshot: item.tax_rule_snapshot.merge("annual_fica_context" => snapshot))
    end

    calls = 0
    allow_any_instance_of(described_class).to receive(:fingerprint_for).and_wrap_original do |method, *args|
      calls += 1
      raise "Historical FICA replay exceeded its fingerprint budget" if calls > 2 * items.size

      method.call(*args)
    end
    result = PayrollFicaLegacyRecovery.new(company: company, year: 2024).inventory
    expect(result[:employee_years].sole[:status]).to eq("ready")
    expect(result[:counts]).to include(proven: 26, recoverable: 0)
    expect(calls).to eq(2 * items.size)
  end
end
