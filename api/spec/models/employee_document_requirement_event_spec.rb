# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocumentRequirementEvent, type: :model do
  let(:requirement) { create(:employee_document_requirement) }
  let(:event) do
    requirement.events.create!(
      company: requirement.company,
      employee: requirement.employee,
      event_type: "status_changed",
      from_status: "missing",
      to_status: "waived",
      note: "Reviewed exception"
    )
  end

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

  it "rejects direct SQL updates at the database boundary" do
    expect do
      described_class.connection.execute(
        "UPDATE employee_document_requirement_events SET note = 'rewritten' WHERE id = #{Integer(event.id)}"
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "rejects direct SQL deletes at the database boundary" do
    expect do
      described_class.connection.execute(
        "DELETE FROM employee_document_requirement_events WHERE id = #{Integer(event.id)}"
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
