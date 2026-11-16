# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeStatusTransitionService do
  include ActiveSupport::Testing::TimeHelpers
  let(:employee) { create(:employee, hire_date: Date.new(2024, 1, 1)) }
  let(:actor) { create(:user, company: employee.company, organization: employee.company.organization, role: :manager) }

  %w[deactivate terminate].each do |action|
    it "blocks #{action} while a run starting on the effective date is approved" do
      run = create(:pay_period, :approved, company: employee.company, start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 15), pay_date: Date.new(2024, 3, 20))
      create(:payroll_item, employee: employee, company: employee.company, pay_period: run)
      expect { described_class.public_send("#{action}!", employee: employee, actor: actor, attributes: { effective_date: "2024-03-01" }) }
        .to raise_error(described_class::Error, "Unapprove pay run ##{run.id} first")
      expect(employee.reload.status).to eq("active")
      expect(employee.employee_status_events).to be_empty
    end
  end

  %w[deactivate terminate].each do |action|
    it "blocks #{action} effective Nov 15 for an approved Nov 16-30 run and lists calculated runs" do
      run = create(:pay_period, :approved, company: employee.company, start_date: "2026-11-16", end_date: "2026-11-30", pay_date: "2026-12-04")
      create(:payroll_item, employee: employee, company: employee.company, pay_period: run)
      expect { described_class.public_send("#{action}!", employee: employee, actor: actor, attributes: { effective_date: "2026-11-15" }) }
        .to raise_error(described_class::Error, "Unapprove pay run ##{run.id} first")
      run.update!(status: "calculated")
      expect(described_class.open_runs(employee, effective_date: "2026-11-15")).to include(run)
      described_class.public_send("#{action}!", employee: employee, actor: actor, attributes: { effective_date: "2026-11-15" })
      service = PayPeriodLifecycleService.new(pay_period: run, actor: actor)
      expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Resolve ineligible workers/)
      run.update_columns(status: "approved")
      expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Resolve ineligible workers/)
      run.update_columns(status: "calculated")
      run.payroll_items.destroy_all
      expect { service.approve! }.to raise_error(PayPeriodLifecycleService::EmptyPayPeriodError)
      expect(PayrollRunEligibility.new(run).payload).to be_empty
    end

    it "exempts explicit special runs from #{action} blocking and eligibility warnings" do
      run = create(:pay_period, :approved, company: employee.company, run_purpose: "final")
      create(:payroll_item, employee: employee, company: employee.company, pay_period: run)
      described_class.public_send("#{action}!", employee: employee, actor: actor, attributes: { effective_date: "2024-01-01" })
      expect(described_class.open_runs(employee)).to be_empty
      expect(PayrollRunEligibility.new(run).payload).to be_empty
    end
  end

  %w[deactivate terminate].each do |action|
    %w[calculated approved].each do |status|
      it "only asks to check the Nov 16–30 #{status} run for #{action} effective Nov 20" do
        travel_to(Time.utc(2026, 11, 21, 12)) do
          run = create(:pay_period, company: employee.company, status: status,
            start_date: "2026-11-16", end_date: "2026-11-30", pay_date: "2026-12-04")
          item = create(:payroll_item, employee: employee, company: employee.company, pay_period: run)
          groups = described_class.open_run_groups(employee, effective_date: "2026-11-20")
          expect(groups[:check]).to include(run)
          expect(groups[:remove]).to be_empty
          described_class.public_send("#{action}!", employee: employee, actor: actor, attributes: { effective_date: "2026-11-20" })
          expect(PayrollRunEligibility.new(run).payload).to be_empty
          expect(item.reload).to be_persisted
        end
      end
    end
  end

  it "accepts a dedicated inactive reason and refuses same-day reactivation" do
    described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15", reason_category: "seasonal" })
    expect { described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" }) }
      .to raise_error(described_class::Error, /after the worker's latest status change/)
  end

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
      [ PayrollBusinessClock.today + 1, Date.new(2023, 12, 31) ].each do |date|
        expect { described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: date }) }.to raise_error(described_class::Error)
      end
      expect(employee.reload.status).to eq("active")
      expect(employee.employee_status_events).to be_empty
    end

    it "lets an accountant mark a worker inactive but not terminate one" do
      actor.update!(role: "accountant")
      expect {
        described_class.terminate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
      }.to raise_error(described_class::Error, /Client configuration access required/)
      expect(employee.reload.status).to eq("active")

      described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-03-15" })
      expect(employee.reload.status).to eq("inactive")
      expect(employee.employee_status_events.sole).to have_attributes(event_type: "deactivated", actor_id: actor.id)
    end
  end

  it "accepts today's Guam date while UTC is still on the previous day" do
    travel_to Time.utc(2026, 11, 16, 22, 31) do # 8:31 a.m. Nov 17 in Guam
      event = described_class.deactivate!(employee: employee, actor: actor, attributes: { effective_date: "2026-11-17" })
      expect(event.effective_date).to eq(Date.new(2026, 11, 17))
      expect { described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2026-11-18" }) }
        .to raise_error(described_class::Error, /cannot be in the future/)
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

    it "lets an accountant reactivate an inactive worker" do
      employee.update!(status: "inactive")
      actor.update!(role: "accountant")
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      expect(employee.reload.status).to eq("active")
      expect(employee.employee_status_events.sole).to have_attributes(event_type: "reactivated", actor_id: actor.id)
    end

    it "keeps rehiring a terminated worker with client configuration" do
      employee.update!(status: "terminated", termination_date: "2024-03-15")
      actor.update!(role: "accountant")
      expect {
        described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      }.to raise_error(described_class::Forbidden, "A manager or admin can rehire a terminated worker")
      expect(employee.reload.status).to eq("terminated")

      actor.update!(role: "manager")
      described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      expect(employee.reload.status).to eq("active")
    end

    it "does not let a client user reactivate an inactive worker" do
      employee.update!(status: "inactive")
      actor.update!(role: "client")
      expect {
        described_class.reactivate!(employee: employee, actor: actor, attributes: { effective_date: "2024-04-01" })
      }.to raise_error(described_class::Error, /Payroll staff access required/)
      expect(employee.reload.status).to eq("inactive")
      expect(employee.employee_status_events).to be_empty
    end
  end
end
