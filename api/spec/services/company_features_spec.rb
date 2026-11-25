# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyFeatures do
  it "finds the first day of the current uninterrupted stubs activation" do
    company = create(:company)
    start = Date.new(2026, 8, 1)
    [ false, true, true, false, true ].each_with_index do |enabled, index|
      ClientOperatingProfile.create!(
        company: company, version: index + 1, effective_on: start + index.days, ends_on: start + index.days,
        offering: "payroll_portals", hours_source: "manual", employee_portal_enabled: enabled,
        options: { "employee_portal" => { "features" => { "stubs" => enabled } } }
      )
    end
    activate_employee_app!(company)
    expect(described_class.for(company, on: start + 2.days).employee_stubs_enabled_since).to eq(start + 1.day)
    expect(described_class.for(company, on: start + 3.days).employee_stubs_enabled_since).to be_nil
    expect(described_class.for(company, on: start + 4.days).employee_stubs_enabled_since).to eq(start + 4.days)
  end

  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }

  describe "backfill and dual-read agreement across all company shapes" do
    it "agrees with legacy columns for AIRE (aire_services connected app)" do
      aire = create(
        :company,
        organization: organization,
        name: "AIRE Services",
        kind_of_employer: "N",
        filing_contact_name: "AIRE Admin",
        phone: "671-555-0100",
        email: "payroll@aire.example.com"
      )
      create(:pay_period, company: aire, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 15), pay_date: Date.new(2026, 1, 20))
      TimeTrackingSource.create!(
        company: aire,
        name: "AIRE Time",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret-token-value",
        active: true,
        cutoff_enforcement_starts_on: Date.new(2026, 1, 1)
      )

      result = ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: aire.id))
      expect(result).to eq({ created: 1, skipped: 0 })

      features = described_class.for(aire, on: Date.new(2026, 1, 15))
      expect(features).to be_persisted
      expect(features.effective_on).to eq(Date.new(2026, 1, 1))
      expect(features.offering).to eq("workforce_suite")
      expect(features.hours_source).to eq("connected_app")
      expect(features).to be_connected_app
      expect(features.intake_adapter).to be_nil
      expect(features.intake_required_sources).to eq([])
      expect(features.overtime_mode).to eq("source_reports")
      expect(features.tips_default).to eq("paid_in_check")
      expect(features.client_portal?).to be(false)
      expect(features.employee_portal_enabled?).to be(false)
      expect(features.subdomain_enabled?).to be(false)
      expect(features.time_module_enabled?).to be(false)
      expect(features.year_end_kind_of_employer).to eq(aire.kind_of_employer)
      expect(features.year_end_contact).to eq(name: "AIRE Admin", phone: "671-555-0100", email: "payroll@aire.example.com")
    end

    it "agrees with legacy columns for MoSa's (mosa_revel with custom and default payroll_intake_settings)" do
      mosa = create(
        :company,
        organization: organization,
        name: "MoSa's Joint",
        client_payroll_approval_required: true,
        payroll_intake_source_types: [ "mosa_revel" ],
        payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } }
      )
      create(:pay_period, company: mosa, start_date: Date.new(2026, 2, 2), end_date: Date.new(2026, 2, 15), pay_date: Date.new(2026, 2, 19))

      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: mosa.id))

      features = described_class.for(mosa, on: Date.new(2026, 2, 15))
      expect(features).to be_persisted
      expect(features.effective_on).to eq(Date.new(2026, 2, 2))
      expect(features.offering).to eq("payroll_portals")
      expect(features.hours_source).to eq("intake_adapter")
      expect(features.intake_adapter).to eq("mosa_revel")
      expect(features.intake_adapter?("mosa_revel")).to be(true)
      expect(features.intake_required_sources).to eq(mosa.payroll_intake_required_sources("mosa_revel"))
      expect(features.intake_required_sources).to eq([ "revel_hours" ])
      expect(features.tips_default).to eq("paid_in_check")
      expect(features.overtime_mode).to eq("source_reports")
      expect(features.workweek_alignment).to eq("warn_if_offset")
      expect(features.client_portal?).to be(true)
      expect(features.employee_portal_enabled?).to be(false)
      expect(features.subdomain_enabled?).to be(false)
      expect(features.time_module_enabled?).to be(false)

      # Also confirm default required_sources agreement when payroll_intake_settings is empty
      mosa_default = create(
        :company,
        organization: organization,
        name: "MoSa's Default Settings",
        payroll_intake_source_types: [ "mosa_revel" ],
        payroll_intake_settings: {}
      )
      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: mosa_default.id))
      default_features = described_class.for(mosa_default)
      expect(default_features.intake_required_sources).to eq(mosa_default.payroll_intake_required_sources("mosa_revel"))
      expect(default_features.intake_required_sources).to eq(%w[revel_hours supplemental_workbook])
    end

    it "agrees with legacy columns for Spike (spike_email)" do
      spike = create(
        :company,
        organization: organization,
        name: "Spike Coffee Roasters",
        client_payroll_approval_required: false,
        payroll_intake_source_types: [ "spike_email" ],
        payroll_intake_settings: {}
      )
      create(:pay_period, company: spike, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 14), pay_date: Date.new(2026, 3, 20))

      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: spike.id))

      features = described_class.for(spike, on: Date.new(2026, 3, 14))
      expect(features).to be_persisted
      expect(features.offering).to eq("payroll_service")
      expect(features.hours_source).to eq("intake_adapter")
      expect(features.intake_adapter).to eq("spike_email")
      expect(features.intake_adapter?("spike_email")).to be(true)
      expect(features.intake_required_sources).to eq(spike.payroll_intake_required_sources("spike_email"))
      expect(features.tips_default).to eq("already_paid_out")
      expect(features.overtime_mode).to eq("weekly_split")
      expect(features.workweek_alignment).to eq("aligned")
      expect(features.client_portal?).to be(false)
      expect(features.employee_portal_enabled?).to be(false)
      expect(features.subdomain_enabled?).to be(false)
      expect(features.time_module_enabled?).to be(false)
    end

    it "agrees with legacy columns for manual companies with and without active client portal users" do
      plain_manual = create(:company, organization: organization, name: "Plain Manual Co", client_payroll_approval_required: false)
      kpi_manual = create(:company, organization: organization, name: "KPI Manual Portal Co", client_payroll_approval_required: false)
      create(:user, organization: organization, company: kpi_manual, role: "client", active: true)

      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: [ plain_manual.id, kpi_manual.id ]))

      plain_features = described_class.for(plain_manual)
      expect(plain_features).to be_persisted
      expect(plain_features.offering).to eq("payroll_service")
      expect(plain_features.hours_source).to eq("manual")
      expect(plain_features.intake_adapter).to be_nil
      expect(plain_features.client_portal?).to be(false)
      expect(plain_features.employee_portal_enabled?).to be(false)

      kpi_features = described_class.for(kpi_manual)
      expect(kpi_features).to be_persisted
      expect(kpi_features.offering).to eq("payroll_service")
      expect(kpi_features.hours_source).to eq("manual")
      expect(kpi_features.client_portal?).to be(true)
      expect(kpi_features.employee_portal_enabled?).to be(false)
    end

    it "skips test workspaces in backfill, falls back cleanly, and keeps employee_portal and subdomain disabled" do
      source = create(
        :company,
        organization: organization,
        name: "MoSa's Live",
        client_payroll_approval_required: true,
        payroll_intake_source_types: [ "mosa_revel" ]
      )
      workspace = create(
        :company,
        organization: organization,
        name: "MoSa's Sandbox",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: source,
        migration_rehearsal_status: "ready",
        client_payroll_approval_required: true,
        payroll_intake_source_types: [ "mosa_revel" ]
      )

      result = ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: [ source.id, workspace.id ]))
      expect(result).to eq({ created: 1, skipped: 1 })
      expect(workspace.client_operating_profiles).to be_empty

      workspace_features = described_class.for(workspace)
      expect(workspace_features).not_to be_persisted
      expect(workspace_features.offering).to eq("payroll_portals")
      expect(workspace_features.hours_source).to eq("intake_adapter")
      expect(workspace_features.intake_adapter).to eq("mosa_revel")
      expect(workspace_features.client_portal?).to be(true)
      expect(workspace_features.employee_portal_enabled?).to be(false)
      expect(workspace_features.subdomain_enabled?).to be(false)

      # Even if a profile row on a test workspace has employee_portal_enabled or subdomain_enabled true,
      # CompanyFeatures enforces false on test workspaces.
      ClientOperatingProfile.create!(
        company: workspace,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_portals",
        hours_source: "intake_adapter",
        intake_adapter: "mosa_revel",
        client_portal_enabled: true,
        employee_portal_enabled: true,
        options: OperatingProfileCatalog.default_options.merge(
          "subdomain_enabled" => true,
          "employee_portal" => {
            # Locked switches can't be stored on at all (M4-9d).
            "features" => OperatingProfileCatalog::EMPLOYEE_PORTAL_FEATURES.index_with do |feature|
              !CompanyFeatures::LOCKED_OFF.include?("employee_portal.features.#{feature}")
            end,
            "former_access_years" => 6
          }
        )
      )
      rechecked = described_class.for(workspace)
      expect(rechecked).to be_persisted
      expect(rechecked.employee_portal_enabled?).to be(false)
      expect(rechecked.employee_portal_feature?(:stubs)).to be(false)
      expect(rechecked.subdomain_enabled?).to be(false)
    end

    it "matches User#accessible_company_ids for archived assignments, unarchived assignments, foreign orgs, and practice logins" do
      home_archived_only = create(:company, organization: organization, name: "Home With Archived Assignment", client_payroll_approval_required: false)
      archived_workspace = create(
        :company,
        organization: organization,
        name: "Archived Sandbox",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: home_archived_only,
        migration_rehearsal_status: "ready",
        test_workspace_archived_at: 1.day.ago
      )
      archived_client = create(:user, organization: organization, company: home_archived_only, role: "client", active: true)
      # Insert an unexpired assignment to the archived company (bypassing test-workspace role guard to mirror legacy data).
      CompanyAssignment.insert_all!([ {
        user_id: archived_client.id,
        company_id: archived_workspace.id,
        expires_at: 30.days.from_now,
        created_at: Time.current,
        updated_at: Time.current
      } ])

      home_reassigned = create(:company, organization: organization, name: "Home With Active Reassignment", client_payroll_approval_required: false)
      active_assigned = create(:company, organization: organization, name: "Active Assigned Client Co", client_payroll_approval_required: false)
      reassigned_client = create(:user, organization: organization, company: home_reassigned, role: "client", active: true)
      create(:company_assignment, user: reassigned_client, company: active_assigned)

      home_foreign_assigned = create(:company, organization: organization, name: "Home With Foreign Assignment", client_payroll_approval_required: false)
      foreign_org = create(:organization)
      foreign_company = create(:company, organization: foreign_org, name: "Foreign Org Target", client_payroll_approval_required: false)
      foreign_assigned_client = create(:user, organization: organization, company: home_foreign_assigned, role: "client", active: true)
      CompanyAssignment.insert_all!([ {
        user_id: foreign_assigned_client.id,
        company_id: foreign_company.id,
        expires_at: 30.days.from_now,
        created_at: Time.current,
        updated_at: Time.current
      } ])

      practice_source = create(:company, organization: organization, name: "Practice Source Live Co", client_payroll_approval_required: false)
      open_sandbox = create(
        :company,
        organization: organization,
        name: "Open Practice Sandbox",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: practice_source,
        migration_rehearsal_status: "ready",
        test_workspace_expires_at: 30.days.from_now,
        client_payroll_approval_required: false
      )
      practice_login = create(
        :user,
        organization: organization,
        company: open_sandbox,
        practice_company: open_sandbox,
        role: "client",
        active: true
      )
      create(:company_assignment, user: practice_login, company: open_sandbox)

      expect(archived_client.accessible_company_ids).to eq([ home_archived_only.id ])
      expect(reassigned_client.accessible_company_ids).to eq([ active_assigned.id ])
      expect(foreign_assigned_client.accessible_company_ids).to eq([ home_foreign_assigned.id ])
      expect(practice_login.accessible_company_ids).to eq([ open_sandbox.id ])

      live_targets = [
        home_archived_only,
        home_reassigned,
        active_assigned,
        home_foreign_assigned,
        foreign_company,
        practice_source
      ]
      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: live_targets.map(&:id)))

      expect(described_class.for(home_archived_only).client_portal?).to be(true)
      expect(described_class.for(home_reassigned).client_portal?).to be(false)
      expect(described_class.for(active_assigned).client_portal?).to be(true)
      expect(described_class.for(home_foreign_assigned).client_portal?).to be(true)
      expect(described_class.for(foreign_company).client_portal?).to be(false)
      expect(described_class.for(practice_source).client_portal?).to be(false)
      expect(described_class.for(open_sandbox).client_portal?).to be(true)

      open_sandbox.update_column(:test_workspace_archived_at, Time.current)
      expect(described_class.for(open_sandbox.reload).client_portal?).to be(false)

      # Verify the migration backfill produces identical client_portal_enabled results.
      ClientOperatingProfile.where(company_id: live_targets.map(&:id)).delete_all
      require Rails.root.join("db/migrate/20261122050000_create_client_operating_profiles")
      CreateClientOperatingProfiles.new.send(:backfill_existing_companies!)

      expect(ClientOperatingProfile.find_by!(company_id: home_archived_only.id).client_portal_enabled).to be(true)
      expect(ClientOperatingProfile.find_by!(company_id: home_reassigned.id).client_portal_enabled).to be(false)
      expect(ClientOperatingProfile.find_by!(company_id: active_assigned.id).client_portal_enabled).to be(true)
      expect(ClientOperatingProfile.find_by!(company_id: home_foreign_assigned.id).client_portal_enabled).to be(true)
      expect(ClientOperatingProfile.find_by!(company_id: foreign_company.id).client_portal_enabled).to be(false)
      expect(ClientOperatingProfile.find_by!(company_id: practice_source.id).client_portal_enabled).to be(false)
      expect(ClientOperatingProfile.where(company_id: [ archived_workspace.id, open_sandbox.id ])).to be_empty
    end

    it "is idempotent when re-run and produces identical output from the migration backfill helper" do
      mosa = create(
        :company,
        organization: organization,
        payroll_intake_source_types: [ "mosa_revel" ],
        payroll_intake_settings: { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } },
        client_payroll_approval_required: true
      )
      spike = create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ])
      aire = create(:company, organization: organization)
      TimeTrackingSource.create!(
        company: aire,
        name: "AIRE Migration Backfill",
        source_type: "aire_services",
        base_url: "https://aire-backfill.example.com",
        shared_secret: "secret-token-value",
        active: true,
        cutoff_enforcement_starts_on: Date.new(2026, 1, 1)
      )
      manual = create(:company, organization: organization)
      target_ids = [ mosa.id, spike.id, aire.id, manual.id ]

      first_run = ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: target_ids))
      second_run = ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: target_ids))

      expect(first_run).to eq({ created: 4, skipped: 0 })
      expect(second_run).to eq({ created: 0, skipped: 4 })
      service_snapshots = ClientOperatingProfile.where(company_id: target_ids).order(:company_id).map do |profile|
        profile.attributes.slice(
          "company_id", "effective_on", "ends_on", "version", "offering", "hours_source",
          "intake_adapter", "client_portal_enabled", "employee_portal_enabled"
        ).merge("options" => profile.resolved_options)
      end

      # Clear and run the migration's self-contained backfill twice to verify parity and idempotency.
      ClientOperatingProfile.where(company_id: target_ids).delete_all
      require Rails.root.join("db/migrate/20261122050000_create_client_operating_profiles")
      migration = CreateClientOperatingProfiles.new
      migration.send(:backfill_existing_companies!)
      migration.send(:backfill_existing_companies!)
      # That migration seeded the old 6-year former-access default; the later
      # reset brings the migrated rows to today's catalog default.
      require Rails.root.join("db/migrate/20261125120100_reset_former_access_years_default")
      ResetFormerAccessYearsDefault.new.up

      migration_snapshots = ClientOperatingProfile.where(company_id: target_ids).order(:company_id).map do |profile|
        profile.attributes.slice(
          "company_id", "effective_on", "ends_on", "version", "offering", "hours_source",
          "intake_adapter", "client_portal_enabled", "employee_portal_enabled"
        ).merge("options" => profile.resolved_options)
      end

      expect(migration_snapshots).to eq(service_snapshots)
    end
  end

  describe "effective-dated resolution, review_first?, and employee_portal_feature?" do
    let(:company) { create(:company, organization: organization) }

    it "resolves historical and current versions by date" do
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        ends_on: Date.new(2026, 6, 30),
        version: 1,
        offering: "payroll_service",
        hours_source: "manual",
        client_portal_enabled: false,
        employee_portal_enabled: false,
        options: { "overtime" => { "mode" => "weekly_split" } }
      )
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 7, 1),
        ends_on: nil,
        version: 2,
        offering: "payroll_portals",
        hours_source: "intake_adapter",
        intake_adapter: "mosa_revel",
        client_portal_enabled: true,
        employee_portal_enabled: false,
        options: { "overtime" => { "mode" => "source_reports" } }
      )

      june = described_class.for(company, on: Date.new(2026, 6, 15))
      july = described_class.for(company, on: Date.new(2026, 7, 15))

      expect(june.version).to eq(1)
      expect(june.offering).to eq("payroll_service")
      expect(june.overtime_mode).to eq("weekly_split")
      expect(june.client_portal?).to be(false)

      expect(july.version).to eq(2)
      expect(july.offering).to eq("payroll_portals")
      expect(july.intake_adapter).to eq("mosa_revel")
      expect(july.overtime_mode).to eq("source_reports")
      expect(july.client_portal?).to be(true)
    end

    it "always enforces review_first? for bank, w4, and identity and reads switches for configurable groups" do
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_portals",
        hours_source: "manual",
        client_portal_enabled: true,
        employee_portal_enabled: false,
        options: {
          "client_portal" => {
            "review_first" => {
              "profile" => false,
              "contact" => false,
              "address" => true,
              "pay" => true,
              "termination" => true
            }
          }
        }
      )

      features = described_class.for(company, on: Date.new(2026, 2, 1))
      expect(features.review_first?(:bank)).to be(true)
      expect(features.review_first?(:w4)).to be(true)
      expect(features.review_first?(:identity)).to be(true)
      expect(features.review_first?(:profile)).to be(false)
      expect(features.review_first?(:contact)).to be(false)
      expect(features.review_first?(:address)).to be(true)
      expect { features.review_first?(:unknown_group) }.to raise_error(ArgumentError)
    end

    it "gates employee_portal_feature? on employee_portal_enabled? and rejects unknown features" do
      profile = ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        version: 1,
        offering: "payroll_portals",
        hours_source: "manual",
        client_portal_enabled: true,
        employee_portal_enabled: false,
        options: {
          "employee_portal" => {
            "features" => { "stubs" => true }
          }
        }
      )

      expect(described_class.for(company, on: Date.new(2026, 2, 1)).employee_portal_feature?(:stubs)).to be(false)

      profile.update!(employee_portal_enabled: true)
      # The flags alone open nothing; the switch's activation does (M4-9d).
      expect(described_class.for(company, on: Date.new(2026, 2, 1)).employee_portal_feature?(:stubs)).to be(false)
      activate_employee_app!(company)
      features = described_class.for(company, on: Date.new(2026, 2, 1))
      expect(features.employee_portal_feature?(:stubs)).to be(true)
      expect(features.employee_portal_feature?(:bank_requests)).to be(false)
      expect { features.employee_portal_feature?(:unknown_feature) }.to raise_error(ArgumentError)
    end

    it "falls back to legacy columns when no persisted profile exists yet without leaking into the association" do
      legacy = create(:company, organization: organization, name: "Legacy Spike Co", payroll_intake_source_types: [ "spike_email" ])
      features = described_class.for(legacy)

      expect(features).not_to be_persisted
      expect(features.offering).to eq("payroll_service")
      expect(features.hours_source).to eq("intake_adapter")
      expect(features.intake_adapter).to eq("spike_email")
      expect(features.tips_default).to eq("already_paid_out")
      expect(legacy.client_operating_profiles.target).to be_empty

      legacy.update!(name: "Legacy Spike Co Renamed")
      expect(ClientOperatingProfile.where(company_id: legacy.id).count).to eq(0)
    end

    it "defaults on: and nil fallback to the Guam business date (PayrollBusinessClock.today)" do
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 1, 1),
        ends_on: Date.new(2026, 6, 30),
        version: 1,
        offering: "payroll_service",
        hours_source: "manual"
      )
      ClientOperatingProfile.create!(
        company: company,
        effective_on: Date.new(2026, 7, 1),
        ends_on: nil,
        version: 2,
        offering: "payroll_portals",
        hours_source: "intake_adapter",
        intake_adapter: "mosa_revel",
        client_portal_enabled: true
      )

      # 2026-06-30 16:00 UTC is 2026-07-01 02:00 ChST (Guam is UTC+10).
      travel_to(Time.utc(2026, 6, 30, 16, 0, 0)) do
        default_features = described_class.for(company)
        nil_features = described_class.for(company, on: nil)

        expect(default_features.as_of).to eq(Date.new(2026, 7, 1))
        expect(default_features.version).to eq(2)
        expect(nil_features.as_of).to eq(Date.new(2026, 7, 1))
        expect(nil_features.version).to eq(2)
      end
    end
  end
end
