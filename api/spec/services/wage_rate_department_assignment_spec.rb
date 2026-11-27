# frozen_string_literal: true

require "rails_helper"

RSpec.describe WageRateDepartmentAssignment do
  it "previews changes, assigns an active mapped primary rate and preserves wage rates" do
    company = create(:company)
    employee = create(:employee, company: company, department: nil)
    unmatched = create(:employee, company: company, department: nil)
    rate = employee.employee_wage_rates.create!(label: "Kitchen rate", rate: 20, is_primary: true, active: true)
    before = rate.attributes
    service = described_class.new(company: company, label_map: { "Kitchen rate" => "Kitchen" })

    expect(service.call(apply: false)).to include(departments_to_create: 1, employees_to_assign: 1, no_mapped_label: 1)
    expect(employee.reload.department_id).to be_nil
    expect(Department.where(company_id: company.id)).to be_empty

    expect(service.call(apply: true)).to include(departments_to_create: 1, employees_to_assign: 1, no_mapped_label: 1)
    expect(employee.reload.department.name).to eq("Kitchen")
    expect(unmatched.reload.department_id).to be_nil
    expect(rate.reload.attributes).to eq(before)
    expect(service.call(apply: true)).to include(departments_to_create: 0, employees_to_assign: 0, already_assigned: 1)
  end

  it "preserves existing departments by default and skips inactive destinations and employees" do
    company = create(:company)
    original = create(:department, company: company, name: "Office")
    destination = create(:department, company: company, name: "Kitchen", active: false)
    employee = create(:employee, company: company, department: original)
    inactive = create(:employee, company: company, department: nil, status: "inactive")
    [ employee, inactive ].each do |person|
      person.employee_wage_rates.create!(label: "Kitchen rate", rate: 20, is_primary: true, active: true)
    end
    service = described_class.new(company: company, label_map: { "Kitchen rate" => "Kitchen" })

    expect(service.call(apply: true, overwrite: true)).to include(inactive_department: 1, employees_to_assign: 0)
    destination.update!(active: true)
    expect(service.call(apply: true)).to include(existing_department_preserved: 1, employees_to_assign: 0)
    expect(employee.reload.department).to eq(original)

    expect(service.call(apply: true, overwrite: true)).to include(employees_to_assign: 1)
    expect(employee.reload.department).to eq(destination)
    expect(inactive.reload.department_id).to be_nil
  end

  it "uses regular earnings from committed reportable non-voided paychecks only" do
    company = create(:company)
    employee = create(:employee, company: company, department: nil)
    [ "Primary", "Kitchen rate", "Dining rate" ].each do |label|
      employee.employee_wage_rates.create!(label: label, rate: 20, is_primary: label == "Primary", active: true)
    end
    [
      [ :committed, false, "Kitchen rate" ], [ :committed, true, "Dining rate" ], [ :draft, false, "Dining rate" ]
    ].each do |status, voided, label|
      pay_period = if status == :committed
        create(:pay_period, :committed, company: company)
      else
        create(:pay_period, company: company)
      end
      item = create(:payroll_item, pay_period: pay_period, employee: employee, voided: voided)
      PayrollItemEarning.create!(payroll_item: item, label: label, category: "regular", amount: 800)
    end
    service = described_class.new(company: company, label_map: { "Kitchen rate" => "Kitchen", "Dining rate" => "Dining" })
    expect(service.call(apply: true)).to include(employees_to_assign: 1, no_mapped_label: 0)
    expect(employee.reload.department.name).to eq("Kitchen")
  end
end
