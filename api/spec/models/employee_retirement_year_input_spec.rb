# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeRetirementYearInput do
  let(:employee) { create(:employee) }
  let(:attributes) do
    { employee: employee, company: employee.company, tax_year: 2026,
      source_reference: "Employee statement and provider reconciliation, September 2026",
      reason: "Initial annual evidence" }
  end

  it "keeps missing prior-year wages unknown rather than silently zero" do
    input = described_class.create!(attributes)
    expect(input.prior_year_wage_status).to eq("unknown")
    expect(input.prior_year_fica_wages).to be_nil
  end

  it "requires a wage amount and evidence for verified wages" do
    input = described_class.new(attributes.merge(prior_year_wage_status: "verified"))
    expect(input).not_to be_valid
    expect(input.errors.attribute_names).to include(:prior_year_fica_wages, :prior_year_wage_source)
  end

  it "requires explicit zero and evidence for a new hire with no prior employer wages" do
    input = described_class.new(attributes.merge(prior_year_wage_status: "no_prior_employer_wages",
      prior_year_fica_wages: 100, prior_year_wage_source: "Prior employer wage report"))
    expect(input).not_to be_valid
    input.prior_year_fica_wages = 0
    expect(input).to be_valid
  end

  it "requires attestation that opening amounts do not duplicate applied payroll" do
    input = described_class.new(attributes.merge(employer_additions_before_system: 200))
    expect(input).not_to be_valid
    input.opening_balances_verified = true
    expect(input).to be_valid
  end

  it "selects the latest append-only correction and snapshots its evidence" do
    first = described_class.create!(attributes)
    latest = described_class.create!(attributes.merge(external_roth_deferrals: 500, reason: "Corrected provider evidence"))
    expect(employee.retirement_year_input_for(2026)).to eq(latest)
    employee.employee_retirement_year_inputs.load
    expect(employee.retirement_year_input_for(2026)).to eq(latest)
    expect(latest.snapshot_attributes).to include(year_input_id: latest.id, external_roth_deferrals: 500.to_d)
    expect(first.update(reason: "Overwrite")).to be(false)
    expect(first.destroy).to be(false)
  end

  it "rejects cross-company records and negative amounts" do
    input = described_class.new(attributes.merge(company: create(:company), external_traditional_deferrals: -1))
    expect(input).not_to be_valid
    expect(input.errors.attribute_names).to include(:company, :external_traditional_deferrals)
  end

  it "prevents SQL updates from overwriting evidence" do
    input = described_class.create!(attributes)
    expect do
      described_class.transaction(requires_new: true) { input.update_columns(reason: "Overwritten") }
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(input.reload.reason).to eq("Initial annual evidence")
  end
end
