# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocumentReadiness do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: "admin") }

  it "creates an idempotent payroll-blocking checklist for a W-2 new hire" do
    employee = create(:employee, company: company)

    2.times { described_class.seed_new_hire!(employee: employee, actor: actor) }

    expect(employee.employee_document_requirements).to contain_exactly(
      have_attributes(requirement_type: "identity_and_work_authorization", status: "missing", required_for_payroll: true),
      have_attributes(requirement_type: "withholding_election", status: "missing", required_for_payroll: true)
    )
  end

  it "creates the contractor tax-form checklist for a 1099 new hire" do
    employee = create(:employee, :contractor, company: company)

    described_class.seed_new_hire!(employee: employee, actor: actor)

    expect(employee.employee_document_requirements).to contain_exactly(
      have_attributes(requirement_type: "contractor_tax_form", status: "missing", required_for_payroll: true)
    )
  end

  it "blocks only payroll items whose required checklist remains unresolved" do
    included = create(:employee, company: company, first_name: "Included", last_name: "Worker")
    excluded = create(:employee, company: company, first_name: "Other", last_name: "Worker")
    period = create(:pay_period, company: company)
    create(:payroll_item, company: company, employee: included, pay_period: period)
    create(:employee_document_requirement, company: company, employee: included)
    create(:employee_document_requirement, company: company, employee: excluded)

    expect { described_class.require_payroll_ready!(period) }
      .to raise_error(described_class::BlockedError, /Included Worker: Signed withholding election \(missing\)/)
  end
end
