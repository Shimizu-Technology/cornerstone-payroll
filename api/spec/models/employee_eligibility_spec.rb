# frozen_string_literal: true

require "rails_helper"

RSpec.describe Employee, ".eligible_for_period" do
  let(:employee) { create(:employee, hire_date: Date.new(2024, 1, 1)) }
  let(:actor) { create(:user, company: employee.company, organization: employee.company.organization, role: :manager) }

  before do
    EmployeeStatusTransitionService.terminate!(
      employee: employee,
      actor: actor,
      attributes: { effective_date: "2024-03-15" }
    )
    EmployeeStatusTransitionService.reactivate!(
      employee: employee,
      actor: actor,
      attributes: { effective_date: "2024-05-01" }
    )
  end

  it "includes the period containing the termination date" do
    expect(described_class.eligible_for_period(Date.new(2024, 3, 1), Date.new(2024, 3, 15))).to include(employee)
  end

  it "excludes a payroll period entirely inside the inactive gap" do
    expect(described_class.eligible_for_period(Date.new(2024, 4, 1), Date.new(2024, 4, 15))).not_to include(employee)
    expect(employee.eligible_on?(Date.new(2024, 4, 8))).to be(false)
  end

  it "includes the reactivation date and later active periods" do
    expect(described_class.eligible_for_period(Date.new(2024, 5, 1), Date.new(2024, 5, 15))).to include(employee)
    expect(employee.eligible_on?(Date.new(2024, 5, 1))).to be(true)
  end
end
