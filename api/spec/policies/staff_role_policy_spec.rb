# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaffRolePolicy do
  describe ".allowed?" do
    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }

    expected_roles = {
      staff_workspace: %w[super_admin org_admin admin manager accountant],
      payroll_operations: %w[super_admin org_admin admin manager accountant],
      manage_client_configuration: %w[super_admin org_admin admin manager],
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

  describe "high-impact endpoint registry" do
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
      %w[preview apply lock archive_unlinked_workers update_worker verify_cutover update_cutover_review approve_cutover].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/historical_imports",
          action_name: action_name
        )).to eq(:manage_client_configuration)
      end
      %w[create update destroy apply apply_to_all_companies clear_active].each do |action_name|
        expect(described_class.capability_for(
          controller_path: "api/v1/admin/printer_profiles",
          action_name: action_name
        )).to eq(:manage_client_configuration)
      end
      expect(described_class.capability_for(
        controller_path: "api/v1/admin/organizations",
        action_name: "index"
      )).to eq(:manage_platform)
    end
  end
end
