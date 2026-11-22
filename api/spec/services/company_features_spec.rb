# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyFeatures do
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

    it "agrees with legacy columns for a test workspace and keeps employee_portal and subdomain disabled" do
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

      ClientOperatingProfiles::BackfillService.call(companies: Company.where(id: [ source.id, workspace.id ]))

      workspace_features = described_class.for(workspace)
      expect(workspace_features).to be_persisted
      expect(workspace_features.offering).to eq("payroll_portals")
      expect(workspace_features.hours_source).to eq("intake_adapter")
      expect(workspace_features.intake_adapter).to eq("mosa_revel")
      expect(workspace_features.client_portal?).to be(true)
      expect(workspace_features.employee_portal_enabled?).to be(false)
      expect(workspace_features.subdomain_enabled?).to be(false)

      # Even if a profile row on a test workspace has employee_portal_enabled or subdomain_enabled true,
      # CompanyFeatures enforces false on test workspaces.
      workspace.client_operating_profiles.first.update!(
        employee_portal_enabled: true,
        options: OperatingProfileCatalog.default_options.merge(
          "subdomain_enabled" => true,
          "employee_portal" => {
            "features" => OperatingProfileCatalog::EMPLOYEE_PORTAL_FEATURES.index_with(true),
            "former_access_years" => 6
          }
        )
      )
      rechecked = described_class.for(workspace)
      expect(rechecked.employee_portal_enabled?).to be(false)
      expect(rechecked.employee_portal_feature?(:stubs)).to be(false)
      expect(rechecked.subdomain_enabled?).to be(false)
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
          "intake_adapter", "client_portal_enabled", "employee_portal_enabled", "options"
        )
      end

      # Clear and run the migration's self-contained backfill twice to verify parity and idempotency.
      ClientOperatingProfile.where(company_id: target_ids).delete_all
      require Rails.root.join("db/migrate/20261122050000_create_client_operating_profiles")
      migration = CreateClientOperatingProfiles.new
      migration.send(:backfill_existing_companies!)
      migration.send(:backfill_existing_companies!)

      migration_snapshots = ClientOperatingProfile.where(company_id: target_ids).order(:company_id).map do |profile|
        profile.attributes.slice(
          "company_id", "effective_on", "ends_on", "version", "offering", "hours_source",
          "intake_adapter", "client_portal_enabled", "employee_portal_enabled", "options"
        )
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
      features = described_class.for(company, on: Date.new(2026, 2, 1))
      expect(features.employee_portal_feature?(:stubs)).to be(true)
      expect(features.employee_portal_feature?(:bank_requests)).to be(false)
      expect { features.employee_portal_feature?(:unknown_feature) }.to raise_error(ArgumentError)
    end

    it "falls back to legacy columns when no persisted profile exists yet" do
      legacy = create(:company, organization: organization, payroll_intake_source_types: [ "spike_email" ])
      features = described_class.for(legacy)

      expect(features).not_to be_persisted
      expect(features.offering).to eq("payroll_service")
      expect(features.hours_source).to eq("intake_adapter")
      expect(features.intake_adapter).to eq("spike_email")
      expect(features.tips_default).to eq("already_paid_out")
    end
  end
end
