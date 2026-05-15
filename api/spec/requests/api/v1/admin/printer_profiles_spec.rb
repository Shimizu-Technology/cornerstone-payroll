# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PrinterProfiles", type: :request do
  let!(:organization) { create(:organization, name: "Cornerstone Firm") }
  let!(:company) { create(:company, organization: organization, name: "Client A", check_stock_type: "top_check") }
  let!(:other_company) { create(:company, organization: organization, name: "Client B") }
  let!(:foreign_organization) { create(:organization, name: "Other Firm") }

  let!(:admin_user) do
    User.create!(
      company: company,
      organization: organization,
      email: "printer-admin@example.com",
      name: "Printer Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_company_id).and_return(company.id)
  end

  describe "GET /api/v1/admin/printer_profiles" do
    it "returns profiles for the active organization, not just the current user" do
      shared_profile = PrinterProfile.create!(
        organization: organization,
        name: "Office LaserJet",
        check_stock_type: "top_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      PrinterProfile.create!(
        organization: foreign_organization,
        name: "Foreign Printer",
        check_stock_type: "top_check",
        check_offset_x: 0,
        check_offset_y: 0
      )

      get "/api/v1/admin/printer_profiles"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("active_printer_profile_id")).to be_nil
      profiles = response.parsed_body.fetch("printer_profiles")
      expect(profiles.map { |profile| profile.fetch("id") }).to eq([shared_profile.id])
      expect(profiles.first.fetch("organization_id")).to eq(organization.id)
    end
  end

  describe "POST /api/v1/admin/printer_profiles" do
    it "creates the profile under the active organization" do
      expect {
        post "/api/v1/admin/printer_profiles",
          params: {
            printer_profile: {
              name: "Front Desk Printer",
              check_stock_type: "bottom_check",
              check_offset_x: "0.125",
              check_offset_y: "-0.025",
              check_layout_config: { check_face: { payee: { x: 70 } } }
            }
          }
      }.to change { organization.printer_profiles.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("printer_profile", "organization_id")).to eq(organization.id)
    end
  end

  describe "POST /api/v1/admin/printer_profiles/:id/apply" do
    it "applies an organization profile to the active company" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025,
        check_layout_config: { "check_face" => { "memo" => { "x" => 50 } } }
      )

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply"

      expect(response).to have_http_status(:ok)
      expect(company.reload.check_stock_type).to eq("bottom_check")
      expect(company.check_offset_x.to_d).to eq(0.125.to_d)
      expect(company.check_offset_y.to_d).to eq(-0.025.to_d)
      expect(company.check_layout_config).to eq("check_face" => { "memo" => { "x" => 50 } })
      expect(company.active_printer_profile_id).to eq(profile.id)
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_id")).to eq(profile.id)
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_name")).to eq("Shared Printer")
    end

    it "does not apply a profile from another organization" do
      foreign_profile = PrinterProfile.create!(
        organization: foreign_organization,
        name: "Foreign Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )

      post "/api/v1/admin/printer_profiles/#{foreign_profile.id}/apply"

      expect(response).to have_http_status(:not_found)
      expect(company.reload.check_stock_type).to eq("top_check")
    end

    it "uses the organization for the switched company context" do
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_company_id).and_return(other_company.id)
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply"

      expect(response).to have_http_status(:ok)
      expect(other_company.reload.check_stock_type).to eq("bottom_check")
      expect(other_company.active_printer_profile_id).to eq(profile.id)
    end
  end

  describe "POST /api/v1/admin/printer_profiles/clear_active" do
    it "clears the active printer profile without changing the current calibration" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )
      company.update!(
        active_printer_profile: profile,
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )

      post "/api/v1/admin/printer_profiles/clear_active"

      expect(response).to have_http_status(:ok)
      expect(company.reload.active_printer_profile_id).to be_nil
      expect(company.check_stock_type).to eq("bottom_check")
      expect(company.check_offset_x.to_d).to eq(0.125.to_d)
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_id")).to be_nil
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_name")).to be_nil
    end
  end
end
