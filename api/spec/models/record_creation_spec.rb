# frozen_string_literal: true

require "rails_helper"

RSpec.describe TracksRecordCreation do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization) }

  after { Current.reset }

  %i[company employee pay_period].each do |type|
    it "records #{type} creation with immutable actor snapshots in the same transaction" do
      Current.user = actor
      attrs = type == :company ? { organization: company.organization } : { company: company, organization: company.organization }
      attrs.delete(:organization) if %i[employee pay_period].include?(type)
      record = create(type, **attrs)
      log = AuditLog.find_by!(record_type: record.class.table_name, record_id: record.id, action: "#{record.class.table_name}#create")
      original_name = actor.name
      original_role = actor.role
      actor.update_columns(name: "Renamed Person", role: User.roles.fetch(original_role == "manager" ? "accountant" : "manager"))
      expect(log.reload).to have_attributes(actor_name: original_name, actor_role: original_role)
      expect(record.created_by_id).to eq(actor.id) if record.has_attribute?(:created_by_id)
    end
  end

  it "rolls the created record back if auditing fails" do
    Current.user = actor
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)
    expect { create(:employee, company: company) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(company.employees.count).to eq(0)
  end

  it "keeps a creator but writes no audit row without a signed-in user" do
    employee = create(:employee, company: company, created_by: actor)
    expect(employee.created_by_id).to eq(actor.id)
    expect(AuditLog.where(record_type: "employees", record_id: employee.id)).to be_empty
  end

  it "keeps a creator the code set explicitly" do
    other = create(:user, company: company, organization: company.organization)
    Current.user = actor
    expect(create(:employee, company: company, created_by: other).created_by_id).to eq(other.id)
  end

  it "does not audit employees copied into a test workspace" do
    Current.user = actor
    source = create(:employee, company: company)
    copy = create(:employee, company: company, test_workspace_source_employee_id: source.id)
    expect(AuditLog.where(record_type: "employees", record_id: copy.id)).to be_empty
  end

  it "rolls audit evidence back with a failed outer transaction" do
    Current.user = actor
    expect do
      Employee.transaction do
        create(:employee, company: company)
        raise ActiveRecord::Rollback
      end
    end.not_to change { AuditLog.count }
  end
end
