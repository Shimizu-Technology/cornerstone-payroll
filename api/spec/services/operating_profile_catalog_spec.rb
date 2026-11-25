# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatingProfileCatalog do
  describe "catalog completeness" do
    it "defines full required metadata for every entry with unique IDs and valid StaffRolePolicy capabilities" do
      expect(described_class.entries).not_to be_empty
      expect(described_class.ids.uniq.length).to eq(described_class.entries.length)

      described_class.entries.each do |entry|
        described_class::REQUIRED_METADATA_FIELDS.each do |field|
          expect(entry.members).to include(field), "Entry #{entry.id} is missing metadata field #{field}"
        end

        expect(entry.id).to be_a(String).and be_present
        expect(entry.label).to be_a(String).and be_present
        expect(entry.section).to be_a(String).and be_present
        expect(entry.storage).to be_in(%i[column option])
        expect(entry.type).to be_a(String).and be_present
        expect(entry.what).to be_a(String).and be_present
        expect(entry.example).to be_a(String).and be_present
        expect(entry.effect).to be_a(String).and be_present
        expect(entry.requires).to be_an(Array)
        expect(StaffRolePolicy::CAPABILITY_ROLES).to have_key(entry.capability),
          "Entry #{entry.id} references unknown capability #{entry.capability.inspect}"

        serialized = entry.as_json
        described_class::REQUIRED_METADATA_FIELDS.each do |field|
          expect(serialized).to have_key(field), "Serialized entry #{entry.id} omits #{field}"
        end
      end
    end

    it "covers every configurable review_first group and excludes always-reviewed groups" do
      described_class::CONFIGURABLE_REVIEW_FIRST_GROUPS.each do |group|
        expect(described_class.find("client_portal.review_first.#{group}")).to be_present
      end

      described_class::ALWAYS_REVIEWED_GROUPS.each do |group|
        expect(described_class.find("client_portal.review_first.#{group}")).to be_nil
      end
    end

    it "defaults all M4-M6 toggles to false" do
      expected_toggles = %w[
        employee_portal_enabled
        employee_portal.features.stubs
        employee_portal.features.tax_forms
        employee_portal.features.profile_requests
        employee_portal.features.delivery_consent
        employee_portal.features.documents
        employee_portal.features.pto
        employee_portal.features.bank_requests
        employee_portal.features.w4_requests
        subdomain_enabled
        time_module_enabled
      ]

      expect(described_class::M4_TO_M6_TOGGLE_IDS).to match_array(expected_toggles)

      expected_toggles.each do |toggle_id|
        entry = described_class.fetch(toggle_id)
        expect(entry.type).to eq("boolean"), "#{toggle_id} must be boolean"
        expect(entry.default).to be(false), "#{toggle_id} must default to false"
      end
    end

    it "produces valid default_options covering every option entry" do
      defaults = described_class.default_options
      expect(described_class.validate_options(defaults)).to eq([])

      described_class.option_entries.each do |entry|
        expect(described_class.option_value(defaults, entry.id)).to eq(entry.default)
      end
    end
  end

  describe ".validate_options" do
    it "rejects unknown top-level and nested keys, including always-reviewed review_first groups" do
      expect(described_class.validate_options({ "unknown_flag" => true }))
        .to include("contains unknown option key 'unknown_flag'")

      expect(described_class.validate_options({ "employee_portal" => { "features" => { "magic" => true } } }))
        .to include("contains unknown option key 'employee_portal.features.magic'")

      %w[bank w4 identity].each do |locked_group|
        errors = described_class.validate_options({ "client_portal" => { "review_first" => { locked_group => false } } })
        expect(errors).to include("contains unknown option key 'client_portal.review_first.#{locked_group}'")
      end
    end

    it "enforces strict types and allowed values" do
      expect(described_class.validate_options("not-a-hash")).to eq([ "must be a JSON object" ])
      expect(described_class.validate_options({ "subdomain_enabled" => "false" }))
        .to include("option 'subdomain_enabled' must be a boolean")
      expect(described_class.validate_options({ "tips" => { "default" => "cash" } }))
        .to include("option 'tips.default' must be one of: paid_in_check, already_paid_out")
      expect(described_class.validate_options({ "employee_portal" => { "former_access_years" => 0 } }))
        .to include("option 'employee_portal.former_access_years' must be an integer between 1 and 10")
      expect(described_class.validate_options({ "employee_portal" => { "former_access_years" => "6" } }))
        .to include("option 'employee_portal.former_access_years' must be an integer between 1 and 10")
      expect(described_class.validate_options({ "client_portal" => { "uploaders" => [ "1" ] } }))
        .to include("option 'client_portal.uploaders' must be 'all_client_users' or an array of positive user IDs")
      expect(described_class.validate_options({ "client_portal" => { "uploaders" => [ 12, 34 ] } })).to eq([])
      expect(described_class.validate_options({ "intake" => { "required_sources" => [ "revel_hours" ] } }, intake_adapter: "mosa_revel")).to eq([])
      expect(described_class.validate_options({ "intake" => { "required_sources" => [ "bogus_role" ] } }, intake_adapter: "mosa_revel"))
        .to include("option 'intake.required_sources' lists unknown mosa_revel source role(s): bogus_role")
      expect(described_class.validate_options({ "intake" => { "required_sources" => [ "revel_hours" ] } }, intake_adapter: nil))
        .to include("option 'intake.required_sources' cannot specify source roles without an intake_adapter")
    end
  end
end
