# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261122050000_create_client_operating_profiles")

RSpec.describe CreateClientOperatingProfiles do
  after do
    ClientOperatingProfile.reset_column_information
    ApplicationRecord.connection.clear_cache!
  end

  it "runs down and up cleanly, restores DB constraints, backfills live companies, and skips test workspaces" do
    organization = create(:organization)
    aire = create(:company, organization: organization, name: "AIRE Migration Co")
    TimeTrackingSource.create!(
      company: aire,
      name: "AIRE Source",
      source_type: "aire_services",
      base_url: "https://aire-mig.example.com",
      shared_secret: "secret-token-value",
      active: true,
      cutoff_enforcement_starts_on: Date.new(2026, 1, 1)
    )
    mosa = create(
      :company,
      organization: organization,
      name: "MoSa Migration Co",
      payroll_intake_source_types: [ "mosa_revel" ],
      payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } },
      client_payroll_approval_required: true
    )
    home_archived_only = create(:company, organization: organization, name: "Archived Assignment Fallback Co")
    archived_workspace = create(
      :company,
      organization: organization,
      name: "Archived Sandbox Co",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: home_archived_only,
      migration_rehearsal_status: "ready",
      test_workspace_archived_at: 1.day.ago
    )
    archived_client = create(:user, organization: organization, company: home_archived_only, role: "client", active: true)
    CompanyAssignment.insert_all!([ {
      user_id: archived_client.id,
      company_id: archived_workspace.id,
      expires_at: 30.days.from_now,
      created_at: Time.current,
      updated_at: Time.current
    } ])

    home_reassigned = create(:company, organization: organization, name: "Reassigned Home Co")
    assigned_target = create(:company, organization: organization, name: "Assigned Target Co")
    reassigned_client = create(:user, organization: organization, company: home_reassigned, role: "client", active: true)
    create(:company_assignment, user: reassigned_client, company: assigned_target)

    pending_workspace = create(
      :company,
      organization: organization,
      name: "Pending Sandbox Co",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: mosa,
      migration_rehearsal_status: "pending"
    )

    migration = described_class.new
    migration.down
    migration.up
    ClientOperatingProfile.reset_column_information
    ApplicationRecord.connection.clear_cache!

    connection = ApplicationRecord.connection
    expect(connection.table_exists?(:client_operating_profiles)).to be(true)
    expect(connection.check_constraint_exists?(:client_operating_profiles, name: "client_operating_profiles_dates_check")).to be(true)
    expect(connection.exclusion_constraints(:client_operating_profiles).map(&:name)).to include("client_operating_profiles_no_overlapping_dates")

    expect(ClientOperatingProfile.find_by!(company_id: aire.id)).to have_attributes(
      version: 1,
      offering: "workforce_suite",
      hours_source: "connected_app",
      intake_adapter: nil
    )
    mosa_profile = ClientOperatingProfile.find_by!(company_id: mosa.id)
    expect(mosa_profile).to have_attributes(
      version: 1,
      offering: "payroll_portals",
      hours_source: "intake_adapter",
      intake_adapter: "mosa_revel",
      client_portal_enabled: true,
      employee_portal_enabled: false
    )
    expect(mosa_profile.option_value("intake.required_sources")).to eq([ "revel_hours" ])
    expect(ClientOperatingProfile.find_by!(company_id: home_archived_only.id).client_portal_enabled).to be(true)
    expect(ClientOperatingProfile.find_by!(company_id: home_reassigned.id).client_portal_enabled).to be(false)
    expect(ClientOperatingProfile.find_by!(company_id: assigned_target.id).client_portal_enabled).to be(true)
    expect(ClientOperatingProfile.where(company_id: [ archived_workspace.id, pending_workspace.id ])).to be_empty
  end
end
