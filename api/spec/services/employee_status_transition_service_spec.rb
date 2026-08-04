# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeStatusTransitionService do
  let(:employee) { create(:employee, hire_date: Date.new(2024, 1, 1)) }
  let(:actor) { create(:user, company: employee.company, organization: employee.company.organization, role: :manager) }

  it "records the effective termination separately from the time it was entered" do
    event = described_class.terminate!(
      employee: employee,
      actor: actor,
      attributes: {
        effective_date: "2024-03-15",
        last_worked_on: "2024-03-14",
        reason_category: "voluntary",
        internal_notes: "Employee provided written notice."
      }
    )

    expect(employee.reload).to have_attributes(status: "terminated", termination_date: Date.new(2024, 3, 15))
    expect(event).to have_attributes(
      event_type: "terminated",
      effective_date: Date.new(2024, 3, 15),
      last_worked_on: Date.new(2024, 3, 14),
      actor: actor
    )
  end

  it "requires reactivation to occur after the recorded termination" do
    described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })

    expect do
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
    end.to raise_error(described_class::Error, /after the termination date/)
  end

  it "does not allow audit history to be edited" do
    event = described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })

    expect(event.update(internal_notes: "rewritten")).to be(false)
    expect(event.errors[:base]).to include("Employee status history is immutable")
  end
end
