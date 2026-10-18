# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Delegated client management" do
  include ActiveSupport::Testing::TimeHelpers
  let(:company) { create(:company) }
  let(:accountant) { create(:user, company: company, role: "accountant") }
  let(:admin) { create(:user, company: company, role: "admin") }
  let!(:assignment) { create(:company_assignment, user: accountant, company: company, client_management: true, granted_by: admin) }

  def allowed?(capability = :manage_client_configuration, target = company)
    StaffRolePolicy.allowed?(accountant, capability, company: target)
  end

  it "grants only the three scoped capabilities and leaves global capabilities unchanged" do
    expect(allowed?).to be(true)
    expect(allowed?(:manage_client_check_settings)).to be(true)
    expect(allowed?(:manage_client_administration)).to be(true)
    expect(StaffRolePolicy.allowed?(accountant, :manage_client_configuration)).to be(false)
    expect(StaffRolePolicy.capabilities_for(accountant)).not_to include("manage_client_configuration", "manage_client_check_settings", "manage_client_administration", "manage_source_delegations")
    %i[manage_organization manage_platform manage_source_delegations manage_payroll_go_live_setup manage_printer_profile_library].each do |capability|
      expect(allowed?(capability)).to be(false)
    end
    expect(accountant.reload.role).to eq("accountant")
  end

  it "keeps existing manager and administrator source credential permissions role-only" do
    User.roles.each_key do |role|
      user = build(:user, role: role, company: company)
      expected = StaffRolePolicy.allowed?(user, :manage_client_configuration)
      expect(StaffRolePolicy.allowed?(user, :manage_source_delegations, company: company)).to eq(expected)
      expect(StaffRolePolicy.allowed?(user, :manage_payroll_go_live_setup, company: company)).to eq(expected)
      expect(StaffRolePolicy.capabilities_for(user)).not_to include(*StaffRolePolicy::ROLE_ONLY_CAPABILITIES.map(&:to_s))
    end
  end

  it "never substitutes home access for an actual grant" do
    assignment.destroy!
    expect(accountant.can_access_company?(company.id)).to be(true)
    expect(allowed?).to be(false)
  end

  it "requires a grant for the actual company" do
    other = create(:company, organization: company.organization)
    create(:company_assignment, user: accountant, company: other)
    expect(allowed?(:manage_client_configuration, other)).to be(false)
  end

  it "rejects even a forged cross-organization assignment" do
    foreign = create(:company)
    assignment.update_columns(company_id: foreign.id)
    expect(allowed?(:manage_client_configuration, foreign)).to be(false)
  end

  it "rechecks the stored assignment after a collection and access list were cached" do
    accountant.company_assignments.load
    accountant.accessible_company_ids
    assignment.update!(client_management: false)
    expect(allowed?).to be(false)
  end

  it "bypasses the request query cache when a grant is revoked outside Active Record" do
    ActiveRecord::Base.cache do
      expect(allowed?).to be(true)
      # A different process's revocation would not invalidate this request's
      # query cache. A raw write reproduces that without a shared test DB.
      ActiveRecord::Base.connection.raw_connection.exec_params(
        "UPDATE company_assignments SET client_management = false WHERE id = $1", [ assignment.id ])
      expect(allowed?).to be(false)
    end
  end

  it "rechecks expiry, including the exact expiry instant" do
    travel_to(Time.current.change(usec: 0)) do
      assignment.update!(expires_at: Time.current)
      expect(allowed?).to be(false)
    end
  end

  it "rechecks deleted assignments" do
    accountant.company_assignments.load
    assignment.destroy!
    expect(allowed?).to be(false)
  end

  it "rechecks stored user activity" do
    User.where(id: accountant.id).update_all(active: false)
    expect(allowed?).to be(false)
  end

  it "rechecks stored role" do
    User.where(id: accountant.id).update_all(role: User.roles.fetch("client"))
    expect(allowed?).to be(false)
  end

  it "rechecks the stored user organization" do
    User.where(id: accountant.id).update_all(organization_id: create(:organization).id)
    expect(allowed?).to be(false)
  end

  it "rechecks company activity" do
    Company.where(id: company.id).update_all(active: false)
    expect(allowed?).to be(false)
  end

  it "rechecks organization activity" do
    Organization.where(id: company.organization_id).update_all(status: "inactive")
    expect(allowed?).to be(false)
  end

  it "never delegates into a workspace even if the stored grant is forged" do
    Company.where(id: company.id).update_all(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_rehearsal_status: "ready", migration_source_company_id: create(:company, organization: company.organization).id)
    expect(allowed?).to be(false)
  end

  it "denies a missing target and unknown actor" do
    expect(allowed?(:manage_client_configuration, nil)).to be(false)
    expect(StaffRolePolicy.client_management_allowed?(nil, company)).to be(false)
  end
end
