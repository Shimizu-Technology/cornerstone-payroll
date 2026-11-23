# frozen_string_literal: true

require "rails_helper"

# M3-4 invariant 3: every employee-creation path records the initial pay
# version (and a version per wage rate) inside its creation transaction.
# Paths with heavier fixtures assert the same in their own specs: QuickBooks
# client bootstrap, go-live setup transfer, test workspaces and rehearsal
# promotion.
RSpec.describe "Initial compensation history on employee creation" do
  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }

  it "writes the initial version in the same transaction as the employee" do
    employee_id = nil
    Employee.transaction do
      employee_id = create(:employee, company: company, pay_rate: 21).id
      expect(EmployeeCompensationChange.where(employee_id: employee_id).sole).to have_attributes(pay_rate: 21, ends_on: nil)
      raise ActiveRecord::Rollback
    end
    expect(EmployeeCompensationChange.where(employee_id: employee_id)).to be_empty
  end

  it "records the employee bulk import as the source" do
    import = EmployeeBulkImport::ImportService.new(company, actor: admin)
    row = {
      "first_name" => "Alex", "last_name" => "Worker", "employment_type" => "hourly", "pay_rate" => "15.00",
      "pay_frequency" => "biweekly", "hire_date" => "2026-01-01", "w4_effective_on" => "2026-01-01",
      "address_line1" => "123 Marine Corps Dr", "city" => "Hagatna", "state" => "GU", "zip" => "96910", "ssn" => "123-45-6789"
    }
    import.create_employees!([ { row_number: 2, attributes: import.send(:build_attributes, row, {}), raw: row } ])

    expect(company.employees.sole.employee_compensation_changes.sole).to have_attributes(
      pay_rate: 15, effective_on: Date.new(2026, 1, 1), source: "bulk_import", created_by_id: admin.id
    )
  end

  it "records a classification transition's new worker record with its own wage rate" do
    super_admin = create(:user, company: company, role: "super_admin")
    contractor = create(:employee, :contractor, company: company, ssn_encrypted: "123-45-6789", hire_date: Date.new(2024, 1, 1))
    result = EmployeeClassificationTransitionService.new(
      employee: contractor,
      attributes: {
        employment_type: "hourly", effective_date: PayrollBusinessClock.today.iso8601, reason: "Worker begins W-2 employment",
        pay_rate: 9.25, pay_frequency: "semimonthly", filing_status: "single", ssn: "123-45-6789", ssn_confirmation: "123-45-6789"
      },
      actor: super_admin
    ).call

    worker = result.new_employee.reload
    expect(worker.employee_compensation_changes.sole).to have_attributes(pay_rate: 9.25, source: "classification_transition", created_by_id: super_admin.id)
    expect(worker.employee_wage_rates.sole.employee_wage_rate_versions.sole).to have_attributes(rate: 9.25, active: true, created_by_id: super_admin.id)
  end

  it "records a client portal employee as pending, then the approved rate replaces it before any payroll" do
    client = create(:user, company: company, organization: company.organization, role: "client")
    result = ClientEmployeeUpdateService.new(
      employee: Employee.new(company: company),
      attrs: {
        first_name: "Portal", last_name: "Hire", hire_date: "2026-01-05", employment_type: "hourly", pay_rate: 14,
        pay_frequency: "biweekly", filing_status: "single", allowances: 0, ssn_encrypted: "123-45-6780", w4_effective_on: "2026-01-05",
        address_line1: "1 Main St", city: "Hagatna", state: "GU", zip: "96910"
      },
      requested_by: client,
      company: company
    ).create!
    pending = result.employee
    expect(pending.employee_compensation_changes.sole).to have_attributes(pay_rate: 0, source: "client_portal", created_by_id: client.id)

    result.change_request.apply!(actor: admin)
    expect(pending.reload.pay_rate).to eq(14)
    expect(pending.employee_compensation_changes.sole).to have_attributes(pay_rate: 14, source: "client_approved", created_by_id: admin.id)
  end

  it "records an admin-created employee and its first wage rate" do
    employee = create(:employee, company: company, hire_date: Date.new(2026, 2, 1))
    rate = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
    expect(employee.employee_compensation_changes.sole).to have_attributes(source: "employee_creation", effective_on: Date.new(2026, 2, 1))
    expect(rate.employee_wage_rate_versions.sole).to have_attributes(effective_on: Date.new(2026, 2, 1), source: "wage_rate_created")
  end
end
