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
    allow_any_instance_of(Api::V1::Admin::PrinterProfileSelectionsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PrinterProfileSelectionsController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::PrinterProfileSelectionsController).to receive(:current_company_id).and_return(company.id)
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
      expect(response.parsed_body.dig("printer_profile", "created_by_id")).to eq(admin_user.id)
    end
  end

  describe "POST /api/v1/admin/printer_profiles/:id/apply" do
    it "selects an organization profile for only the current operator" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "top_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025,
        check_layout_config: { "check_face" => { "memo" => { "x" => 50 } } }
      )

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply"

      expect(response).to have_http_status(:ok)
      expect(company.reload.check_stock_type).to eq("top_check")
      expect(company.check_offset_x.to_d).to eq(0.to_d)
      expect(company.active_printer_profile_id).to be_nil
      selection = admin_user.user_printer_profile_selections.find_by(check_stock_type: "top_check")
      expect(selection&.printer_profile_id).to eq(profile.id)
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

    it "uses the organization for the switched company context without mutating that company" do
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
      expect(other_company.reload.active_printer_profile_id).to be_nil
      expect(admin_user.user_printer_profile_selections.find_by(check_stock_type: "bottom_check")&.printer_profile_id).to eq(profile.id)
    end
  end

  describe "POST /api/v1/admin/printer_profiles/:id/apply_to_all_companies" do
    it "rejects the retired company-wide printer assignment" do
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

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("personal")
      [ company, other_company ].each do |client|
        client.reload
        expect(client.active_printer_profile_id).to be_nil
      end
      expect(foreign_company.reload.check_stock_type).to eq("top_check")
    end

    it "requires manager or admin access" do
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
      expect(response.parsed_body.fetch("error")).to eq("Printer profile library management access required")
      expect(company.reload.check_stock_type).to eq("top_check")
      expect(other_company.reload.active_printer_profile_id).to be_nil
    end
  end

  describe "POST /api/v1/admin/printer_profiles/clear_active" do
    it "clears only the current operator selection without changing company calibration" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0.125,
        check_offset_y: -0.025
      )
      company.update!(check_stock_type: "bottom_check", check_offset_x: 0.125, check_offset_y: -0.025)
      UserPrinterProfileSelection.create!(user: admin_user, organization: organization,
        check_stock_type: "bottom_check", printer_profile: profile)

      post "/api/v1/admin/printer_profiles/clear_active"

      expect(response).to have_http_status(:ok)
      expect(admin_user.user_printer_profile_selections.find_by(check_stock_type: "bottom_check")).to be_nil
      expect(company.check_stock_type).to eq("bottom_check")
      expect(company.check_offset_x.to_d).to eq(0.125.to_d)
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_id")).to be_nil
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_name")).to be_nil
    end
  end

  describe "DELETE /api/v1/admin/printer_profiles/:id" do
    it "archives a profile and clears personal selections" do
      profile = PrinterProfile.create!(
        organization: organization,
        name: "Shared Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      UserPrinterProfileSelection.create!(user: admin_user, organization: organization,
        check_stock_type: "bottom_check", printer_profile: profile)

      delete "/api/v1/admin/printer_profiles/#{profile.id}"

      expect(response).to have_http_status(:no_content)
      expect(profile.reload.archived_at).to be_present
      expect(admin_user.user_printer_profile_selections.find_by(printer_profile_id: profile.id)).to be_nil
      expect(organization.printer_profiles.active).not_to include(profile)
    end
  end

  describe "personal printer profile selections" do
    let!(:profile) do
      PrinterProfile.create!(organization: organization, name: "Office Printer",
        check_stock_type: "top_check", check_offset_x: 0.1, check_offset_y: -0.05)
    end

    it "lets a payroll operator select a shared profile without changing another operator" do
      colleague = create(:user, company: company, organization: organization, role: "accountant")

      put "/api/v1/admin/printer_profile_selections/top_check", params: { printer_profile_id: profile.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("selection", "printer_profile_id")).to eq(profile.id)
      expect(admin_user.user_printer_profile_selections.find_by(check_stock_type: "top_check")&.printer_profile_id).to eq(profile.id)
      expect(colleague.user_printer_profile_selections).to be_empty
      expect(company.reload.active_printer_profile_id).to be_nil
    end

    it "rejects a profile calibrated for a different stock" do
      put "/api/v1/admin/printer_profile_selections/bottom_check", params: { printer_profile_id: profile.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error").downcase).to include("top check")
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

    it "allows an accountant to create a shared profile" do
      expect {
        post "/api/v1/admin/printer_profiles", params: {
          printer_profile: {
            name: "Accounting Room Printer",
            check_stock_type: "top_check",
            check_offset_x: "0.05",
            check_offset_y: "-0.02"
          }
        }
      }.to change { organization.printer_profiles.count }.by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("printer_profile", "created_by_id")).to eq(accountant.id)
    end

    it "does not let an accountant replace the organization default while creating a profile" do
      default_profile = PrinterProfile.create!(
        organization: organization,
        name: "Organization Default",
        check_stock_type: "top_check",
        check_offset_x: 0,
        check_offset_y: 0,
        is_default: true
      )

      post "/api/v1/admin/printer_profiles", params: {
        printer_profile: {
          name: "Accounting Room Printer",
          check_stock_type: "top_check",
          check_offset_x: 0,
          check_offset_y: 0,
          is_default: true
        }
      }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("printer_profile", "is_default")).to be(false)
      expect(default_profile.reload).to be_is_default
    end

    it "denies edits and archives of another person's profile" do
      original_profile = profile.attributes.slice("name", "check_offset_x", "check_offset_y")
      original_company = company.attributes.slice(
        "check_stock_type", "check_offset_x", "check_offset_y", "active_printer_profile_id"
      )

      requests = [
        -> { patch "/api/v1/admin/printer_profiles/#{profile.id}", params: { printer_profile: { name: "Unauthorized" } } },
        -> { delete "/api/v1/admin/printer_profiles/#{profile.id}" }
      ]

      requests.each do |request|
        request.call

        expect(response).to have_http_status(:forbidden)
      end

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply_to_all_companies"
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Printer profile library management access required")

      expect(organization.printer_profiles.count).to eq(1)
      expect(profile.reload.attributes.slice(*original_profile.keys)).to eq(original_profile)
      expect(company.reload.attributes.slice(*original_company.keys)).to eq(original_company)
      expect(other_company.reload.active_printer_profile_id).to be_nil
    end

    it "lets an accountant edit and archive an unused profile they created" do
      own_profile = PrinterProfile.create!(
        organization: organization,
        created_by: accountant,
        name: "My Printer",
        check_stock_type: "top_check",
        check_offset_x: 0,
        check_offset_y: 0
      )

      patch "/api/v1/admin/printer_profiles/#{own_profile.id}", params: {
        printer_profile: { name: "My Updated Printer", check_offset_x: 0.125 }
      }

      expect(response).to have_http_status(:ok)
      expect(own_profile.reload).to have_attributes(name: "My Updated Printer", check_offset_x: 0.125)

      delete "/api/v1/admin/printer_profiles/#{own_profile.id}"

      expect(response).to have_http_status(:no_content)
      expect(own_profile.reload).to be_archived
    end

    it "lets an accountant clone another profile into an owned, editable revision" do
      post "/api/v1/admin/printer_profiles/#{profile.id}/clone"

      expect(response).to have_http_status(:created)
      copy = PrinterProfile.order(:id).last
      expect(copy).to have_attributes(
        created_by_id: accountant.id,
        source_profile_id: profile.id,
        revision_number: 2,
        check_offset_x: profile.check_offset_x,
        check_offset_y: profile.check_offset_y,
        is_default: false
      )
      expect(response.parsed_body.dig("printer_profile", "can_edit")).to be(true)
      expect(response.parsed_body.dig("printer_profile", "owned_by_current_user")).to be(true)

      post "/api/v1/admin/printer_profiles/#{profile.id}/clone"

      expect(response).to have_http_status(:created)
      expect(PrinterProfile.order(:revision_number).last).to have_attributes(
        source_profile_id: profile.id,
        revision_number: 3,
        name: "Protected Printer copy 2"
      )
    end

    it "keeps selected calibrations immutable and directs the owner to clone" do
      own_profile = PrinterProfile.create!(
        organization: organization,
        created_by: accountant,
        name: "Selected Printer",
        check_stock_type: "top_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      UserPrinterProfileSelection.create!(
        user: accountant,
        organization: organization,
        check_stock_type: "top_check",
        printer_profile: own_profile
      )

      patch "/api/v1/admin/printer_profiles/#{own_profile.id}", params: {
        printer_profile: { check_offset_x: 0.25 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Clone")
      expect(own_profile.reload.check_offset_x.to_d).to eq(0.to_d)

      patch "/api/v1/admin/printer_profiles/#{own_profile.id}", params: {
        printer_profile: { description: "Tray 2" }
      }

      expect(response).to have_http_status(:ok)
      expect(own_profile.reload.description).to eq("Tray 2")
    end

    it "allows the compatibility endpoints to manage only the accountant's selection" do
      company.update!(check_stock_type: "bottom_check")

      post "/api/v1/admin/printer_profiles/#{profile.id}/apply"

      expect(response).to have_http_status(:ok)
      expect(accountant.user_printer_profile_selections.find_by(check_stock_type: "bottom_check")&.printer_profile_id).to eq(profile.id)

      post "/api/v1/admin/printer_profiles/clear_active"

      expect(response).to have_http_status(:ok)
      expect(accountant.user_printer_profile_selections.find_by(check_stock_type: "bottom_check")).to be_nil
    end
  end
end
