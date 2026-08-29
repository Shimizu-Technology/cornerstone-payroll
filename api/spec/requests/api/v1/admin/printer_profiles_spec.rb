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
      expect(profiles.map { |profile| profile.fetch("id") }).to eq([ shared_profile.id ])
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

  describe "POST /api/v1/admin/printer_profiles/:id/apply_to_all_companies" do
    it "applies an organization printer profile to every company in the organization" do
      foreign_company = create(:company, organization: foreign_organization, check_stock_type: "top_check")
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Firmwide Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025,
        check_layout_config: { "check_face" => { "memo" => { "x" => 50 } } }
      )

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply_to_all_companies"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("applied_count")).to eq(2)
      [ company, other_company ].each do |client|
        client.reload
        expect(client.check_stock_type).to eq("bottom_check")
        expect(client.check_offset_x.to_d).to eq(0.125.to_d)
        expect(client.check_offset_y.to_d).to eq(-0.025.to_d)
        expect(client.check_layout_config).to eq("check_face" => { "memo" => { "x" => 50 } })
        expect(client.active_printer_profile_id).to eq(profile.id)
      end
      expect(foreign_company.reload.check_stock_type).to eq("top_check")
    end

    it "requires firm admin access" do
      accountant = User.create!(
        company: company,
        organization: organization,
        email: "printer-accountant@example.com",
        name: "Printer Accountant",
        role: "accountant",
        active: true
      )
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Firmwide Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user).and_return(accountant)
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user_id).and_return(accountant.id)

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply_to_all_companies"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Admin access required")
      expect(company.reload.check_stock_type).to eq("top_check")
      expect(other_company.reload.active_printer_profile_id).to be_nil
    end
  end


  describe "manager mutation boundaries" do
    let!(:manager) do
      User.create!(
        company: company,
        organization: organization,
        email: "printer-manager@example.com",
        name: "Printer Manager",
        role: "manager",
        active: true
      )
    end
    let!(:profile) do
      PrinterProfile.create!(
        organization: organization,
        name: "Firm Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )
    end

    before do
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user).and_return(manager)
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user_id).and_return(manager.id)
    end

    it "can apply a shared profile to the active client" do
      post "/api/v1/admin/printer_profiles/#{profile.id}/apply"

      expect(response).to have_http_status(:ok)
      expect(company.reload.active_printer_profile_id).to eq(profile.id)
    end

    it "cannot create, edit, delete, or apply shared profiles firmwide" do
      requests = [
        -> { post "/api/v1/admin/printer_profiles", params: { printer_profile: { name: "Unauthorized", check_stock_type: "top_check" } } },
        -> { patch "/api/v1/admin/printer_profiles/#{profile.id}", params: { printer_profile: { name: "Unauthorized" } } },
        -> { delete "/api/v1/admin/printer_profiles/#{profile.id}" },
        -> { post "/api/v1/admin/printer_profiles/#{profile.id}/apply_to_all_companies" }
      ]

      requests.each do |request|
        request.call
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.fetch("error")).to eq("Admin access required")
      end

      expect(profile.reload.name).to eq("Firm Printer")
      expect(other_company.reload.active_printer_profile_id).to be_nil
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

  describe "DELETE /api/v1/admin/printer_profiles/:id" do
    it "deletes an active profile and clears company active references" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      company.update!(active_printer_profile: profile)

      expect {
        delete "/api/v1/admin/printer_profiles/#{profile.id}"
      }.to change { PrinterProfile.exists?(profile.id) }.from(true).to(false)

      expect(response).to have_http_status(:no_content)
      expect(company.reload.active_printer_profile_id).to be_nil
    end
  end

  describe "accountant mutation boundaries" do
    let!(:accountant) do
      User.create!(
        company: company,
        organization: organization,
        email: "printer-accountant@example.com",
        name: "Printer Accountant",
        role: "accountant",
        active: true
      )
    end
    let!(:profile) do
      PrinterProfile.create!(
        organization: organization,
        name: "Protected Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )
    end

    before do
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user).and_return(accountant)
      allow_any_instance_of(Api::V1::Admin::PrinterProfilesController).to receive(:current_user_id).and_return(accountant.id)
    end

    it "allows read-only printer-profile access" do
      get "/api/v1/admin/printer_profiles"
      expect(response).to have_http_status(:ok)

      get "/api/v1/admin/printer_profiles/#{profile.id}"
      expect(response).to have_http_status(:ok)
    end

    it "denies every printer-profile mutation without persisting changes" do
      original_profile = profile.attributes.slice("name", "check_offset_x", "check_offset_y")
      original_company = company.attributes.slice(
        "check_stock_type", "check_offset_x", "check_offset_y", "active_printer_profile_id"
      )

      requests = [
        -> { post "/api/v1/admin/printer_profiles", params: { printer_profile: { name: "Unauthorized", check_stock_type: "top_check" } } },
        -> { patch "/api/v1/admin/printer_profiles/#{profile.id}", params: { printer_profile: { name: "Unauthorized" } } },
        -> { delete "/api/v1/admin/printer_profiles/#{profile.id}" },
        -> { post "/api/v1/admin/printer_profiles/#{profile.id}/apply" },
        -> { post "/api/v1/admin/printer_profiles/#{profile.id}/apply_to_all_companies" },
        -> { post "/api/v1/admin/printer_profiles/clear_active" }
      ]

      requests.each_with_index do |request, index|
        request.call

        expect(response).to have_http_status(:forbidden)
        expected_error = index.in?([ 0, 1, 2, 4 ]) ? "Admin access required" : "Manager or admin access required"
        expect(response.parsed_body.fetch("error")).to eq(expected_error)
      end

      expect(organization.printer_profiles.count).to eq(1)
      expect(profile.reload.attributes.slice(*original_profile.keys)).to eq(original_profile)
      expect(company.reload.attributes.slice(*original_company.keys)).to eq(original_company)
      expect(other_company.reload.active_printer_profile_id).to be_nil
    end
  end
end
