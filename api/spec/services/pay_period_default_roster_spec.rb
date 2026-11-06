# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodDefaultRoster do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, company: company) }
  let!(:hourly) { create(:employee, company: company) }
  let!(:salary) { create(:employee, :salary, company: company) }
  let!(:contractor) { create(:employee, :contractor, company: company) }
  let(:roster) { described_class.new(period) }

  def save_imported_hourly
    create(:payroll_item, company: company, pay_period: period, employee: hourly,
      employment_type: "hourly", import_source: "time_tracking:synthetic-batch", hours_worked: 8)
  end

  it "defaults an ordinary manual run to eligible employees without creating items" do
    expect { expect(roster.employee_ids).to contain_exactly(hourly.id, salary.id, contractor.id) }
      .not_to change(PayrollItem, :count)
  end

  it "adds salary and contractors after imported hourly rows, but not absent hourly employees" do
    save_imported_hourly
    create(:employee, company: company)
    create(:employee, :salary)

    expect(roster.employee_ids).to contain_exactly(hourly.id, salary.id, contractor.id)
  end

  [ false, true ].each do |imported|
    it "respects disabled base salary for a #{imported ? 'connected' : 'manual'} run" do
      save_imported_hourly if imported
      period.update!(includes_base_salary: false)

      expect(roster.employee_ids).to contain_exactly(hourly.id, contractor.id)
      expect(roster.employee_ids(additional_employee_ids: [ salary.id ])).to include(salary.id)
    end
  end

  it "does not default inactive, future hires, or employees terminated before the period" do
    create(:employee, :salary, company: company, status: "inactive")
    create(:employee, :salary, company: company, hire_date: period.end_date + 1)
    create(:employee, :salary, company: company, status: "terminated", termination_date: period.start_date - 1)

    expect(roster.employee_ids).to contain_exactly(hourly.id, salary.id, contractor.id)
  end

  it "honors exclusions even when the same employee is submitted again" do
    save_imported_hourly
    PayPeriodExcludedEmployee.create!(pay_period: period, employee: salary)

    expect(roster.employee_ids(additional_employee_ids: [ salary.id ])).to contain_exactly(hourly.id, contractor.id)
  end

  it "retains a calculated roster and only adds employees explicitly entered" do
    save_imported_hourly
    period.update!(status: "calculated")

    expect(roster.employee_ids).to eq([ hourly.id ])
    expect(roster.employee_ids(additional_employee_ids: [ salary.id ])).to contain_exactly(hourly.id, salary.id)
  end

  it "does not expand an adjustment roster even when base salary is enabled" do
    period.update!(run_purpose: "adjustment", includes_base_salary: true)
    expect(roster.employee_ids).to be_empty
    save_imported_hourly
    expect(roster.employee_ids).to eq([ hourly.id ])
  end

  it "never expands a correction roster from defaults or omitted-selection input maps" do
    correction = create(:pay_period, :correction_run, company: company)
    create(:payroll_item, company: company, pay_period: correction, employee: hourly)

    expect(described_class.new(correction).employee_ids(additional_employee_ids: [ salary.id ])).to eq([ hourly.id ])
  end
end
