# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeW4ElectionChangeService do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, w4_effective_on: Date.new(2024, 1, 1)) }
  let(:actor) { create(:user, company: company, organization: company.organization) }

  def election_attributes(overrides = {})
    EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) }
      .merge(overrides)
  end

  it "appends a dated election and preserves the prior version" do
    described_class.new(
      employee: employee,
      attributes: election_attributes,
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election"
    ).call!

    described_class.new(
      employee: employee,
      attributes: election_attributes(
        filing_status: "married",
        additional_withholding: 25,
        w4_effective_on: Date.new(2025, 7, 1)
      ),
      actor: actor,
      source: "staff",
      reason: "New signed W-4 received"
    ).call!

    expect(employee.employee_w4_elections.count).to eq(2)
    expect(employee.w4_election_on(Date.new(2025, 6, 30)).filing_status).to eq("single")
    expect(employee.w4_election_on(Date.new(2025, 7, 1)).filing_status).to eq("married")
    expect(employee.reload.filing_status).to eq("married")
  end

  it "requires an effective date and explanation for a changed election" do
    described_class.new(
      employee: employee,
      attributes: election_attributes,
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election"
    ).call!

    expect {
      described_class.new(
        employee: employee,
        attributes: election_attributes(filing_status: "married", w4_effective_on: nil),
        actor: actor,
        source: "staff",
        reason: ""
      ).call!
    }.to raise_error(described_class::Error, /effective date/i)
  end

  it "does not create duplicate history when the submitted election is unchanged" do
    service = described_class.new(
      employee: employee,
      attributes: election_attributes,
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election"
    )
    service.call!

    expect { service.call! }.not_to change(EmployeeW4Election, :count)
  end

  it "does not treat string-form controller values as a changed election" do
    described_class.new(
      employee: employee,
      attributes: election_attributes,
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election"
    ).call!

    controller_values = election_attributes.transform_values do |value|
      value.in?([ true, false ]) ? value.to_s : value&.to_s
    end

    expect {
      described_class.new(
        employee: employee,
        attributes: controller_values,
        actor: actor,
        source: "staff",
        reason: ""
      ).call!
    }.not_to change(EmployeeW4Election, :count)
  end

  it "makes persisted elections append-only" do
    election = described_class.new(
      employee: employee,
      attributes: election_attributes,
      actor: actor,
      source: "employee_creation",
      reason: "Initial W-4 election"
    ).call!

    expect(election.update(filing_status: "married")).to be(false)
    expect(election.destroy).to be(false)
    expect(election.reload.filing_status).to eq("single")
  end
end
