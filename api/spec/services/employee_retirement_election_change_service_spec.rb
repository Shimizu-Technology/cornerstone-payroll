# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeRetirementElectionChangeService do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:attributes) do
    {
      effective_on: "2026-09-01",
      plan_name: "MoSa 401(k)",
      eligible: true,
      participating: true,
      traditional_contribution_type: "percentage",
      traditional_rate: 0.06,
      traditional_amount: 0,
      roth_contribution_type: "fixed",
      roth_rate: 0,
      roth_amount: 125,
      eligible_compensation: "gross_excluding_tips",
      catch_up_enabled: true,
      limit_priority: "traditional_first",
      employer_match_mode: "employee_deferral_percentage",
      employer_match_rate: 1,
      employer_match_deferral_cap_rate: 0.04,
      employer_match_ytd_before_system: 400,
      employer_match_destination: "traditional",
      true_up_policy: "year_to_date"
    }
  end

  it "appends an election and keeps legacy percentage caches compatible" do
    election = described_class.new(
      employee: employee, attributes: attributes, actor: nil, source: "staff", reason: "Signed election received"
    ).call!

    expect(election).to be_persisted
    expect(election.roth_amount).to eq(125)
    expect(employee.reload).to have_attributes(retirement_rate: 0.06.to_d, roth_retirement_rate: 0.to_d)
  end

  it "does not append a duplicate when the same typed values are submitted" do
    2.times do
      described_class.new(
        employee: employee, attributes: attributes, actor: nil, source: "staff", reason: "Signed election received"
      ).call!
    end

    expect(employee.employee_retirement_elections.count).to eq(1)
  end

  it "requires a reason for a later changed election" do
    described_class.new(
      employee: employee, attributes: attributes, actor: nil, source: "staff", reason: "Initial setup"
    ).call!

    expect do
      described_class.new(
        employee: employee,
        attributes: attributes.merge(effective_on: "2026-10-04", traditional_rate: 0.08),
        actor: nil,
        source: "staff",
        reason: ""
      ).call!
    end.to raise_error(described_class::Error, /Explain why/)
  end

  it "rejects a compensation match true-up when YTD eligible compensation cannot be reconstructed" do
    unsupported = attributes.merge(
      employer_match_mode: "compensation_percentage",
      eligible_compensation: "gross_excluding_tips"
    )

    expect do
      described_class.new(
        employee: employee, attributes: unsupported, actor: nil, source: "staff", reason: "Signed election"
      ).call!
    end.to raise_error(ActiveRecord::RecordInvalid, /True up policy can only reconcile/)
  end
end
