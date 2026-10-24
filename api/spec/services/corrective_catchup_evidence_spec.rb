# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PR381 2026 catch-up proof probes" do
  include_context "corrective payroll ledger fixtures", tax_year: 2026

  [ [ 24450, 75, 11.25 ], [ 24470, 55, -3.75 ] ].each do |external, hours, delta|
    it "accepts proved 2026 catch-up with external Roth #{external} and target #{hours} hours" do
      employee.update!(retirement_rate: 0.05, date_of_birth: Date.new(1970, 12, 31))
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2026, prior_year_wage_status: "no_prior_employer_wages", prior_year_fica_wages: 0, prior_year_wage_source: "Verified no prior-year employer wages", source_reference: "Synthetic evidence", reason: "Review proof", external_roth_deferrals: external)
      original=original!
      expect(original.retirement_payment).to eq(45)
      expect(original.retirement_rule_snapshot["catch_up_permission_status"]).to eq("permitted")
      frozen=freeze_history(original)
      preview_result=preview(hours_worked: hours)
      expect(preview_result.dig(:deltas, :retirement_payment)).to eq(delta)
      correction=issue({ hours_worked: hours }, digest: preview_result.dig(:meta, :review_digest))
      expect(correction.retirement_payment).to eq(delta)
      expect(employee.ytd_totals_for(2026).reload.retirement).to eq(45+delta)
      expect(freeze_history(original.reload)).to eq(frozen)
    end
  end

  [ [ 1970, 32450 ], [ 1964, 35700 ], [ 1962, 32450 ] ].each do |birth_year, external|
    it "retains proved standard/enhanced catch-up at age #{2026 - birth_year} with outside Roth above the base" do
      employee.update!(retirement_rate: 0.05, date_of_birth: Date.new(birth_year, 12, 31))
      verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
      employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2026, prior_year_wage_status: "no_prior_employer_wages",
        prior_year_fica_wages: 0, prior_year_wage_source: "Verified no prior-year wages", source_reference: "Synthetic verified evidence", reason: "Catch-up proof", external_roth_deferrals: external)
      original!
      correction = issue(hours_worked: 75)
      expect(correction.retirement_payment).to eq(5)
      expect(employee.ytd_totals_for(2026).reload.retirement).to eq(50)
      expect(PayrollRetirementCatchUp.for_item(correction)).to eq(5)
      refund = issue(hours_worked: 55)
      expect(refund.retirement_payment).to eq(-8.75)
      expect(employee.ytd_totals_for(2026).reload.retirement).to eq(41.25)
      assert_cash(refund)
    end
  end

  it "holds genuinely changed catch-up evidence and rejects its stale review digest" do
    employee.update!(retirement_rate: 0.05, date_of_birth: Date.new(1970, 12, 31))
    verify_synthetic_retirement_plan!(employee, period.pay_date, catch_up_enabled: true)
    input = employee.employee_retirement_year_inputs.create!(company: company, tax_year: 2026, prior_year_wage_status: "no_prior_employer_wages",
      prior_year_fica_wages: 0, prior_year_wage_source: "Verified no prior-year wages", source_reference: "Original evidence", reason: "Catch-up proof", external_roth_deferrals: 24450)
    original!
    digest = preview(hours_worked: 55).dig(:meta, :review_digest)
    employee.employee_retirement_year_inputs.create!(input.attributes.except("id", "created_at", "updated_at").merge("external_roth_deferrals" => 24451, "source_reference" => "Changed verified evidence"))
    expect { preview(hours_worked: 75) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /annual retirement/)
    expect { issue(hours_worked: 75) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError)
    expect { issue({ hours_worked: 55 }, digest: digest) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
    expect(employee.ytd_totals_for(2026).reload.retirement).to eq(45)
  end
end
