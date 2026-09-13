# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocumentRequirementEvent, type: :model do
  it "rejects evidence from a different employee or company" do
    company = create(:company)
    employee = create(:employee, company: company)
    requirement = create(:employee_document_requirement, company: company, employee: employee)
    other_document = create(:client_document)
    event = described_class.new(
      employee_document_requirement: requirement,
      company: company,
      employee: employee,
      client_document: other_document,
      event_type: "document_received",
      to_status: "received"
    )

    expect(event).not_to be_valid
    expect(event.errors[:client_document]).to include("must belong to this employee and company")
  end
end
