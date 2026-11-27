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
end
