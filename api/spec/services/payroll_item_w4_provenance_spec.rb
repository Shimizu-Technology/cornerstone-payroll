# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItemW4Provenance do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company:) }
  let(:original_period) { create(:pay_period, :committed, company:) }
  let(:profile) do
    { "form_version" => 2026, "effective_on" => "2026-01-01", "signed_on" => "2026-01-01",
      "source_reference" => "Synthetic dated form", "filing_status_entered" => "single",
      "step2_multiple_jobs" => false, "step3_dependent_credit" => 0,
      "step4a_other_income" => 0, "step4b_deductions" => 0,
      "step4c_configured_extra_withholding" => 0, "legacy_allowances" => 0 }
  end
  let(:original) do
    create(:payroll_item, company:, employee:, pay_period: original_period,
      tax_rule_snapshot: { "w4" => profile.merge("election_id" => 3, "election_source" => "employee_creation") })
  end
  let(:period) do
    create(:pay_period, :committed, company:, cycle: "supplemental", run_purpose: "correction",
      run_purpose_source: "system_correction", includes_base_salary: false, includes_recurring_items: false,
      corrects_pay_period_id: original_period.id)
  end
  let(:item) do
    create(:payroll_item, company:, employee:, pay_period: period, correction_for_payroll_item: original,
      tax_rule_snapshot: { "w4" => profile.merge("election_id" => nil, "election_source" => nil) })
  end

  it "describes inherited original evidence without querying today's election or altering snapshots" do
    employee.update!(w4_dependent_credit: 9_999)
    expect(employee).not_to receive(:w4_election_on)
    before = [ item.reload.attributes.deep_dup, original.reload.attributes.deep_dup ]
    expect(described_class.call(item)).to eq(origin: "original_payroll_snapshot",
      original_payroll_item_id: original.id, original_pay_period_id: original_period.id,
      election_id: 3, election_source: "employee_creation")
    expect(PayrollItemDisclosure.new(item).as_json[:w4_provenance]).to include(election_id: 3)
    expect([ item.reload.attributes, original.reload.attributes ]).to eq(before)
  end

  it "does not cross employee, company or source-period lineage" do
    candidate = item
    candidate.employee_id = employee.id + 100
    expect(described_class.call(candidate)).to be_nil
    candidate.employee_id = employee.id
    candidate.company_id = company.id + 100
    expect(described_class.call(candidate)).to be_nil
    candidate.company_id = company.id
    candidate.pay_period.corrects_pay_period_id = original_period.id + 100
    expect(described_class.call(candidate)).to be_nil
  end

  it "does not attach original identity to a different retained W4 profile" do
    candidate = item
    candidate.tax_rule_snapshot["w4"]["step3_dependent_credit"] = 100
    expect(described_class.call(candidate)).to be_nil
  end

  it "leaves genuinely missing legacy identity and missing profile fields unknown" do
    candidate = item
    candidate.correction_for_payroll_item.tax_rule_snapshot["w4"].delete("election_id")
    expect(described_class.call(candidate)).to be_nil
    candidate.correction_for_payroll_item.tax_rule_snapshot["w4"]["election_id"] = 3
    candidate.tax_rule_snapshot["w4"].delete("signed_on")
    expect(described_class.call(candidate)).to be_nil
  end

  it "keeps an already recorded current identity authoritative" do
    candidate = item
    candidate.tax_rule_snapshot["w4"]["election_id"] = 4
    candidate.tax_rule_snapshot["w4"]["election_source"] = "manual_change"
    expect(described_class.call(candidate)).to be_nil
  end
end
