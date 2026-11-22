# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeAccountLink do
  let(:worker) { create(:employee) }

  it "enforces tenant alignment even when validations are skipped" do
    attrs = { employee_id: worker.id, company_id: create(:company).id }
    expect(described_class.new(attrs)).not_to be_valid

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attrs ]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "refuses a practice workspace in the model and in Postgres" do
    copy = create(:company, organization: worker.company.organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: worker.company, migration_rehearsal_status: "ready")
    employee = create(:employee, company: copy)
    attrs = { employee_id: employee.id, company_id: copy.id }
    expect(described_class.new(attrs)).not_to be_valid

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attrs ]) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "allows history but only one open link per employee" do
    attrs = { employee_id: worker.id, company_id: worker.company_id }
    described_class.create!(**attrs, status: :revoked)
    described_class.create!(**attrs, status: :invited)

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([ attrs ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
