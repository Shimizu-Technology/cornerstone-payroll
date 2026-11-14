# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollStandingChange do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:rate) { create(:employee_wage_rate, employee: employee, rate: 35, label: "Maintenance") }
  let(:attributes) { { company: company, employee: employee, employee_wage_rate: rate, kind: "extra_hours" } }

  it "stores configuration without amounts and audits creation, update and deactivation" do
    item = described_class.create!(attributes)
    item.update!(position: 2)
    item.update!(active: false)
    logs = AuditLog.where(record_type: described_class.name, record_id: item.id)
    expect(logs.count).to eq(3)
    expect(logs.last.metadata.dig("changes", "active")).to eq([ true, false ])
    expect(item.attributes.keys).not_to include("amount", "hours")
    item.destroy!
    expect(logs.reload.last.action).to eq("payroll_standing_changes#destroy")
  end

  it "refuses cross-company employees and another employee's rate" do
    other = create(:employee)
    expect(described_class.new(attributes.merge(employee: other))).not_to be_valid
    expect(described_class.new(attributes.merge(company: other.company))).not_to be_valid
  end

  it "requires allowed kinds, a nonnegative position, an active hourly employee and saved job" do
    [ { kind: "deduction" }, { position: -1 }, { employee_wage_rate: nil } ].each do |invalid|
      expect(described_class.new(attributes.merge(invalid))).not_to be_valid
    end
    employee.update!(status: "inactive")
    expect(described_class.new(attributes)).not_to be_valid
  end

  it "allows staff to deactivate broken defaults and explains a removed job" do
    item = described_class.create!(attributes)
    rate.destroy!
    expect(item.reload.availability_error).to include("missing or inactive")
    expect(item.update(active: false)).to be(true)
  end

  it "limits owner pay to variable salary with no hourly job" do
    owner = create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0)
    expect(described_class.new(company: company, employee: owner, kind: "owner_pay")).to be_valid
    expect(described_class.new(company: company, employee: employee, kind: "owner_pay")).not_to be_valid
  end
end
