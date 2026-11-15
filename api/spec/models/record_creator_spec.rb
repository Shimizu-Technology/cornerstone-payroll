# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecordCreator do
  it "recovers an old creator only from an exact creation event in the record company" do
    employee = create(:employee)
    actor = create(:user, company: employee.company, organization: employee.company.organization)
    AuditLog.where(record_type: "employees", record_id: employee.id).delete_all
    expect(described_class.call(employee)).to be_nil
    AuditLog.record!(user: actor, company_id: employee.company_id, action: "employees#update", record_type: "employees", record_id: employee.id)
    expect(described_class.call(employee)).to be_nil
    AuditLog.record!(user: actor, company_id: create(:company).id, action: "employees#create", record_type: "employees", record_id: employee.id)
    expect(described_class.call(employee)).to be_nil
    event = AuditLog.record!(user: actor, company_id: employee.company_id, action: "employees#create", record_type: "Employee", record_id: employee.id)
    expect(described_class.call(employee)).to include(name: actor.name, role: actor.role, created_at: event.created_at)
  end
end
