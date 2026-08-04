# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeWorkProfile do
  let(:employee) { create(:employee, :salary) }

  it "requires a confirmed salary schedule to total the standard weekly hours" do
    profile = build(:employee_work_profile, employee: employee, daily_schedule: { "monday" => 8 })

    expect(profile).not_to be_valid
    expect(profile.errors[:daily_schedule]).to include("must total the standard weekly hours")
  end

  it "returns the effective profile for a payroll date" do
    old_profile = create(:employee_work_profile, employee: employee, effective_on: Date.new(2024, 1, 1), ends_on: Date.new(2024, 6, 30))
    new_profile = create(:employee_work_profile, employee: employee, effective_on: Date.new(2024, 7, 1))

    expect(described_class.for_date(employee.id, Date.new(2024, 6, 15))).to eq(old_profile)
    expect(described_class.for_date(employee.id, Date.new(2024, 7, 15))).to eq(new_profile)
  end
end
