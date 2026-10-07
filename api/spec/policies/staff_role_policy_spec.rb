# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaffRolePolicy do
  describe ".allowed?" do
    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }

    expected_roles = {
      staff_workspace: %w[super_admin org_admin admin manager accountant],
      payroll_operations: %w[super_admin org_admin admin manager accountant],
      use_printer_profiles: %w[super_admin org_admin admin manager accountant],
      create_printer_profiles: %w[super_admin org_admin admin manager accountant],
      manage_printer_profile_library: %w[super_admin org_admin admin manager],
      manage_client_check_settings: %w[super_admin org_admin admin manager],
      view_record_activity: %w[super_admin org_admin admin manager accountant],
      manage_filing_review: %w[super_admin org_admin admin manager accountant],
      manage_client_configuration: %w[super_admin org_admin admin manager],
      manage_own_aire_account_link: %w[super_admin org_admin admin manager accountant],
      manage_historical_time_reconciliation: %w[super_admin org_admin admin manager accountant],
      manage_organization: %w[super_admin org_admin admin],
      manage_platform: %w[super_admin]
    }

    expected_roles.each do |capability, allowed_roles|
      User.roles.each_key do |role|
        expected = allowed_roles.include?(role)

        it "#{expected ? 'allows' : 'denies'} #{role} for #{capability}" do
          user = build(:user, organization: organization, company: company, role: role)

          expect(described_class.allowed?(user, capability)).to eq(expected)
        end
      end
    end

    it "denies a missing user" do
      expect(described_class.allowed?(nil, :staff_workspace)).to be(false)
    end
  end

  describe ".historical_reconciliation_allowed?" do
    it "uses home fallback only when no current unarchived client assignment exists" do
      home = create(:company)
      target = create(:company, organization: home.organization)
      actor = create(:user, role: "accountant", company: home)
      sql_allowed = ->(company) do
        ApplicationRecord.connection.select_value("SELECT historical_time_reconciliation_actor_allowed(#{actor.id}, #{company.id})")
      end
      expect(sql_allowed.call(home)).to be(true)
      expect(sql_allowed.call(target)).to be(false)
      expect(described_class.historical_reconciliation_allowed?(actor, home)).to be(true)
      assignment = create(:company_assignment, user: actor, company: target)
      actor = User.find(actor.id)
      expect(described_class.historical_reconciliation_allowed?(actor, home)).to be(false)
      expect(sql_allowed.call(home)).to be(false)
      expect(sql_allowed.call(target)).to be(true)
      expect(described_class.historical_reconciliation_allowed?(actor, target)).to be(true)
      assignment.update!(expires_at: 1.minute.ago)
      actor = User.find(actor.id)
      expect(described_class.historical_reconciliation_allowed?(actor, home)).to be(true)
      expect(described_class.historical_reconciliation_allowed?(actor, target)).to be(false)
      expect(sql_allowed.call(home)).to be(true)
      expect(sql_allowed.call(target)).to be(false)
      home.update!(active: false)
      expect(sql_allowed.call(home)).to be(false)
      expect(described_class.historical_reconciliation_allowed?(actor, home)).to be(false)
      expect(described_class.allowed?(actor, :manage_client_configuration)).to be(false)
      expect(described_class.capability_for(controller_path: "api/v1/admin/aire_payroll_calendars", action_name: "publish"))
        .to eq(:manage_client_configuration)
    end
  end

  describe "high-impact endpoint registry" do
    it "separates retirement evidence and election edits from payroll read access" do
      %w[employee_retirement_year_inputs employee_retirement_elections].each do |resource|
        expect(described_class.capability_for(controller_path: "api/v1/admin/#{resource}", action_name: "index")).to eq(:payroll_operations)
        expect(described_class.capability_for(controller_path: "api/v1/admin/#{resource}", action_name: "create")).to eq(:manage_client_configuration)
      end
      %w[create update].each do |action|
        expect(described_class.capability_for(controller_path: "api/v1/admin/annual_retirement_limits", action_name: action)).to eq(:manage_platform)
      end
    end

    it "references real controller actions" do
      described_class::ACTION_CAPABILITIES.each_key do |endpoint|
        controller_path, action_name = endpoint.split("#", 2)
        controller_class = "#{controller_path.camelize}Controller".constantize

        expect(controller_class.action_methods).to include(action_name), endpoint
      end
    end

    it "references real controllers and known capabilities" do
      described_class::CONTROLLER_CAPABILITIES.each do |controller_path, capability|
        expect { "#{controller_path.camelize}Controller".constantize }.not_to raise_error
        expect(described_class::CAPABILITY_ROLES).to have_key(capability)
      end

      described_class::ACTION_CAPABILITIES.each_value do |capability|
        expect(described_class::CAPABILITY_ROLES).to have_key(capability)
      end
    end

    it "keeps the explicitly reviewed endpoint classifications stable" do
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/pay_periods",
        action_name: "commit"
      )).to be_nil
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/pay_schedule_settings",
        action_name: "update"
      )).to eq(:manage_client_configuration)
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/pay_component_tax_rules",
        action_name: "create"
      )).to eq(:manage_organization)
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/historical_imports",
        action_name: "index"
      )).to eq(:payroll_operations)
      %w[show_aire_account_link create_aire_account_link destroy_aire_account_link].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/time_tracking_sources", action_name: action_name
        )).to eq(:manage_own_aire_account_link)
      end
      %w[save_delegation destroy_delegation].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/time_tracking_sources", action_name: action_name
        )).to eq(:manage_client_configuration)
      end
      %w[create_manual_allocation retry_manual_allocation].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/aire_payroll_cockpits", action_name: action_name
        )).to eq(:manage_historical_time_reconciliation)
      end
      %w[preview apply lock archive_unlinked_workers update_worker verify_cutover update_cutover_review approve_cutover preview_ytd_bridge apply_ytd_bridge].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/historical_imports",
          action_name: action_name
        )).to eq(:manage_client_configuration)
      end
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/historical_imports",
        action_name: "download_cutover_evidence"
      )).to eq(:payroll_operations)
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/payroll_filing_responsibilities",
        action_name: "index"
      )).to eq(:payroll_operations)
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/payroll_filing_responsibilities",
        action_name: "upsert"
      )).to eq(:manage_filing_review)
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/printer_profiles",
        action_name: "apply_to_all_companies"
      )).to eq(:manage_printer_profile_library)
      %w[update destroy].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/printer_profiles",
          action_name: action_name
        )).to be_nil
      end
      %w[create clone].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/printer_profiles",
          action_name: action_name
        )).to eq(:create_printer_profiles)
      end
      %w[apply clear_active].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/printer_profiles",
          action_name: action_name
        )).to eq(:use_printer_profiles)
      end
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/organizations",
        action_name: "index"
      )).to eq(:manage_platform)
    end
  end
end
