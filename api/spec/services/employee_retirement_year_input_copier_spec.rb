# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeRetirementYearInputCopier do
  let(:organization) { create(:organization) }
  let(:source) { create(:employee, company: create(:company, organization: organization)) }
  let(:target) { create(:employee, company: create(:company, organization: organization)) }
  let(:actor) { create(:user, company: target.company, organization: organization, role: :admin) }

  def evidence(employee, **overrides)
    employee.employee_retirement_year_inputs.create!({ company: employee.company, tax_year: 2026,
      prior_year_wage_status: "verified", prior_year_fica_wages: 160_000,
      prior_year_wage_source: "Employer W-2GU Box 3", employer_additions_before_system: 1_000,
      opening_balances_verified: true, source_reference: "Provider-certified evidence", reason: "Initial review" }.merge(overrides))
  end

  def copy(mode)
    described_class.call(source: source, target: target, actor: actor, mode: mode)
  end

  it "preserves full history and latest ordering by original creation time before ID" do
    latest = evidence(source, created_at: Time.utc(2026, 10, 5), employer_additions_before_system: 900)
    evidence(source, created_at: Time.utc(2026, 10, 4))
    copy(:history)

    expect(target.employee_retirement_year_inputs.count).to eq(2)
    expect(target.retirement_year_input_for(2026)).to have_attributes(company: target.company, created_by: actor,
      created_at: latest.created_at, employer_additions_before_system: 900.to_d,
      source_reference: latest.source_reference, reason: latest.reason)
    expect { copy(:history) }.not_to change(EmployeeRetirementYearInput, :count)
  end

  it "preserves ID ordering when source records share a creation timestamp" do
    evidence(source, created_at: Time.utc(2026, 10, 5))
    latest = evidence(source, created_at: Time.utc(2026, 10, 5), external_roth_deferrals: 500)
    copy(:history)

    expect(target.retirement_year_input_for(2026).external_roth_deferrals).to eq(latest.external_roth_deferrals)
  end

  it "promotes only the latest record for each year onto a fresh target and is idempotent" do
    evidence(source)
    evidence(source, employer_additions_before_system: 900, reason: "Corrected provider evidence")
    evidence(source, tax_year: 2025, employer_additions_before_system: 800)
    copy(:latest_per_year)

    expect(target.employee_retirement_year_inputs.count).to eq(2)
    expect(target.retirement_year_input_for(2026).employer_additions_before_system).to eq(900.to_d)
    expect(target.retirement_year_input_for(2025).employer_additions_before_system).to eq(800.to_d)
    expect { copy(:latest_per_year) }.not_to change(EmployeeRetirementYearInput, :count)
  end

  it "appends approved evidence when it matches an older target entry but differs from its latest correction" do
    approved = evidence(source)
    old = evidence(target)
    correction = evidence(target, employer_additions_before_system: 2_000, reason: "Prior target correction")
    expect { copy(:latest_per_year) }.to change(target.employee_retirement_year_inputs, :count).by(1)

    expect(target.retirement_year_input_for(2026).snapshot_attributes.except(:year_input_id))
      .to eq(approved.snapshot_attributes.except(:year_input_id))
    expect(old.reload.employer_additions_before_system).to eq(1_000.to_d)
    expect(correction.reload.employer_additions_before_system).to eq(2_000.to_d)
    expect { copy(:latest_per_year) }.not_to change(EmployeeRetirementYearInput, :count)
  end

  it "does not accept cross-organization evidence copies" do
    evidence(source)
    foreign = create(:employee)
    expect do
      described_class.call(source: source, target: foreign, actor: actor, mode: :latest_per_year)
    end.to raise_error(ArgumentError, /same organization/)
    expect(foreign.employee_retirement_year_inputs).to be_empty
  end

  it "makes approved evidence latest even when an existing copied timestamp is ahead of the server clock" do
    approved = evidence(source, employer_additions_before_system: 900)
    existing = evidence(target, created_at: 1.day.from_now)
    copy(:latest_per_year)

    expect(target.retirement_year_input_for(2026).employer_additions_before_system).to eq(approved.employer_additions_before_system)
    expect(existing.reload.employer_additions_before_system).to eq(1_000.to_d)
    expect { copy(:latest_per_year) }.not_to change(EmployeeRetirementYearInput, :count)
  end

  it "retains historical W-2 evidence after the employee later becomes a contractor" do
    original = evidence(source)
    [ source, target ].each do |employee|
      employee.allow_tax_classification_change = true
      employee.update!(employment_type: "contractor", contractor_type: "individual", contractor_pay_type: "flat_fee")
    end
    copy(:history)

    expect(target.retirement_year_input_for(2026).snapshot_attributes.except(:year_input_id))
      .to eq(original.snapshot_attributes.except(:year_input_id))
    expect { evidence(target) }.to raise_error(ActiveRecord::RecordInvalid, /W-2 employee/)
  end

  it "rejects mismatched stored company evidence rather than copying across an undocumented transfer" do
    foreign_company = create(:company, organization: organization)
    input = source.employee_retirement_year_inputs.build(company: foreign_company, tax_year: 2026,
      source_reference: "Transfer evidence", reason: "Retained historical input")
    input.save!(validate: false)

    expect { copy(:history) }.to raise_error(ArgumentError, /different source company/)
    expect(target.employee_retirement_year_inputs).to be_empty
  end

  it "rejects an actor from another organization before copying evidence" do
    evidence(source)
    foreign_actor = create(:user, role: :admin)
    expect do
      described_class.call(source: source, target: target, actor: foreign_actor, mode: :history)
    end.to raise_error(ArgumentError, /actor must belong/)
    expect(target.employee_retirement_year_inputs).to be_empty
  end

  it "still validates the stored evidence rather than bypassing its source requirements" do
    input = source.employee_retirement_year_inputs.build(company: source.company, tax_year: 2026,
      source_reference: "", reason: "Unverified stored data")
    input.save!(validate: false)

    expect { copy(:latest_per_year) }.to raise_error(ActiveRecord::RecordInvalid, /Source reference/)
    expect(target.employee_retirement_year_inputs.reload).to be_empty
  end
end
