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
  describe ".deactivate!" do
    it "preserves eligibility before, during and after an inactive interval" do
      event = described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15", reason_category: "other", internal_notes: "Seasonal pause" })
      expect(event).to have_attributes(event_type: "deactivated", previous_status: "active", resulting_status: "inactive", actor: actor)
      expect(employee.reload.status).to eq("inactive")
      expect(employee.eligible_on?(Date.new(2024, 3, 14))).to be(true)
      expect(employee.eligible_on?(Date.new(2024, 3, 15))).to be(false)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 1), Date.new(2024, 3, 14))).to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 15), Date.new(2024, 3, 31))).not_to include(employee)
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      expect(employee.eligible_on?(Date.new(2024, 4, 1))).to be(true)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 15), Date.new(2024, 3, 31))).not_to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 14))).to include(employee)
      expect(event.update(internal_notes: "Changed")).to be(false)
    end

    it "rejects future and pre-hire dates without changing status" do
      [ Date.current + 1, Date.new(2023, 12, 31) ].each do |date|
        expect { described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: date }) }.to raise_error(described_class::Error)
      end
      expect(employee.reload.status).to eq("active")
      expect(employee.employee_status_events).to be_empty
    end
  end

  describe ".reactivate!" do
    it "reactivates an imported inactive worker without inventing a termination" do
      employee.update!(status: "inactive", termination_date: nil)
      expect(Employee.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 14))).not_to include(employee)

      event = described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })

      expect(employee.reload).to have_attributes(status: "active", termination_date: nil)
      expect(event).to have_attributes(event_type: "reactivated", previous_status: "inactive", resulting_status: "active",
        effective_date: Date.new(2024, 4, 1), actor: actor, company: employee.company)
      expect(employee.employee_status_events.count).to eq(1)
      expect(employee.eligible_on?(Date.new(2024, 3, 31))).to be(false)
      expect(employee.eligible_on?(Date.new(2024, 4, 1))).to be(true)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 18), Date.new(2024, 3, 31))).not_to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 14))).to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 25), Date.new(2024, 4, 7))).to include(employee)
    end

    it "keeps the imported inactive period excluded through a later termination and return" do
      employee.update!(status: "inactive")
      described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })

      expect(employee.eligible_on?(Date.new(2024, 3, 14))).to be(false)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 1), Date.new(2024, 3, 14))).not_to include(employee)
      # The termination falls inside March, but no active period starts until April.
      expect((Date.new(2024, 3, 1)..Date.new(2024, 3, 31)).none? { |date| employee.eligible_on?(date) }).to be(true)
      expect(Employee.eligible_for_period(Date.new(2024, 3, 1), Date.new(2024, 3, 31))).not_to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 14))).to include(employee)
    end

    it "rejects a status change dated before the worker's latest status event" do
      employee.update!(status: "inactive")
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })

      expect {
        described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
      }.to raise_error(described_class::Error, /before the worker's latest status change/)
      expect(employee.reload.status).to eq("active")
      expect(employee.employee_status_events.count).to eq(1)
    end

    it "still reactivates terminated workers and preserves their termination history" do
      described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
      event = described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })

      expect(employee.reload).to have_attributes(status: "active", termination_date: nil)
      expect(event.previous_status).to eq("terminated")
      expect(employee.employee_status_events.pluck(:event_type)).to contain_exactly("terminated", "reactivated")
      expect(Employee.eligible_for_period(Date.new(2024, 3, 18), Date.new(2024, 3, 31))).not_to include(employee)
      expect(Employee.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 14))).to include(employee)
    end

    it "rejects an already active worker without adding history" do
      expect {
        described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      }.to raise_error(described_class::Error, /Only inactive or terminated/)
      expect(employee.employee_status_events).to be_empty
    end

    it "does not let an accountant reactivate an inactive worker" do
      employee.update!(status: "inactive")
      actor.update!(role: "accountant")
      expect {
        described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      }.to raise_error(described_class::Error, /Client configuration access required/)
      expect(employee.reload.status).to eq("inactive")
      expect(employee.employee_status_events).to be_empty
    end
  end
end
