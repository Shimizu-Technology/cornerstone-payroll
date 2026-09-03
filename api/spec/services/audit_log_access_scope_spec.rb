# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditLogAccessScope do
  let!(:organization) { create(:organization) }
  let!(:home_company) { create(:company, organization: organization) }
  let!(:assigned_company) { create(:company, organization: organization) }
  let!(:unassigned_company) { create(:company, organization: organization) }
  let!(:accountant) { create(:user, organization: organization, company: home_company, role: :accountant) }

  before do
    create(:company_assignment, user: accountant, company: home_company)
    create(:company_assignment, user: accountant, company: assigned_company)
  end

  it "scopes a query-only selection to an assigned company" do
    selected = create(:audit_log, organization: organization, company: assigned_company)
    create(:audit_log, organization: organization, company: home_company)

    scope = described_class.new(
      user: accountant,
      current_company_id: home_company.id,
      requested_company_id: assigned_company.id.to_s,
      company_header_present: false
    ).call

    expect(scope.pluck(:id)).to eq([ selected.id ])
  end

  it "uses the resolved assigned company when the selector is in the header" do
    selected = create(:audit_log, organization: organization, company: assigned_company)
    create(:audit_log, organization: organization, company: home_company)

    scope = described_class.new(
      user: accountant,
      current_company_id: assigned_company.id,
      requested_company_id: nil,
      company_header_present: true
    ).call

    expect(scope.pluck(:id)).to eq([ selected.id ])
  end

  it "rejects a query selector that conflicts with the selected header company" do
    access_scope = described_class.new(
      user: accountant,
      current_company_id: home_company.id,
      requested_company_id: assigned_company.id.to_s,
      company_header_present: true
    )

    expect { access_scope.call }.to raise_error(described_class::NotAuthorizedError, "Not authorized")
  end

  it "rejects a query-only selector for an unassigned company" do
    access_scope = described_class.new(
      user: accountant,
      current_company_id: home_company.id,
      requested_company_id: unassigned_company.id.to_s,
      company_header_present: false
    )

    expect { access_scope.call }.to raise_error(described_class::NotAuthorizedError, "Not authorized")
  end

  it "rejects roles outside the audit-history policy before applying a company scope" do
    manager = create(:user, organization: organization, company: home_company, role: :manager)
    access_scope = described_class.new(
      user: manager,
      current_company_id: nil,
      requested_company_id: nil,
      company_header_present: false
    )

    expect { access_scope.call }.to raise_error(
      described_class::NotAuthorizedError,
      StaffRolePolicy.error_message(:view_audit_history)
    )
  end
end
