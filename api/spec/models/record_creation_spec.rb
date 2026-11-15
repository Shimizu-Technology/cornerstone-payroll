# frozen_string_literal: true

require "rails_helper"

RSpec.describe TracksRecordCreation do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization) }

  after { Current.reset }

  %i[company employee pay_period].each do |type|
    it "stores the signed-in user as the #{type}'s creator without writing its own audit row" do
      Current.user = actor
      attrs = type == :company ? { organization: company.organization } : { company: company }
      expect { @record = create(type, **attrs) }.not_to change(AuditLog, :count)
      expect(@record.created_by_id).to eq(actor.id)
    end
  end

  it "keeps a creator the code set explicitly" do
    other = create(:user, company: company, organization: company.organization)
    Current.user = actor
    expect(create(:employee, company: company, created_by: other).created_by_id).to eq(other.id)
  end

  it "leaves the creator unknown when nobody is signed in and none was given" do
    expect(create(:employee, company: company).created_by_id).to be_nil
  end

  it "credits records created inside a test workspace copy to the person who made the copy" do
    workspace = create(:company, organization: company.organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: company, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 1.day.from_now, migration_rehearsal_created_by: actor)
    expect(create(:pay_period, company: workspace).created_by_id).to eq(actor.id)
  end
end
