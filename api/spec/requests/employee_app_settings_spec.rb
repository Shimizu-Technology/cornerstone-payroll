# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee app branding and Help contacts", type: :request do
  let(:organization) { create(:organization) }
  let!(:company_a) { create(:company, organization: organization, name: "Example Grill LLC", phone: "671-555-0100", subdomain_slug: "example-grill") }
  let!(:company_b) { create(:company, organization: organization, name: "Other Kitchen") }
  let!(:client_a) { create(:user, company: company_a, organization: organization, role: "client") }
  let!(:staff) { create(:user, company: company_a, organization: organization, role: "admin") }
  let!(:accountant) { create(:user, company: company_a, organization: organization, role: "accountant") }
  let(:contact) { { name: "Avery Example", role: "General manager", phone: "671-555-0111", email: "avery@example.test", text_ok: true } }

  before do
    CompanyAssignment.create!(user: client_a, company: company_a)
    CompanyAssignment.create!(user: accountant, company: company_a)
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT)
  end

  def act_as(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  def headers_for(company)
    { "X-Company-Id" => company.id.to_s }
  end

  def client_path(suffix = "")
    "/api/v1/client/employee_app_settings#{suffix}"
  end

  def admin_path(suffix = "")
    "/api/v1/admin/employee_app_settings#{suffix}"
  end

  def enable_subdomain(company)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service",
      hours_source: "manual", options: { subdomain_enabled: true }
    )
    TenantSubdomainRegistry.invalidate!
  end

  describe "who can change the settings" do
    it "lets a client user change their own company and refuses another company" do
      act_as(client_a)

      patch client_path("/branding"), params: { branding: { display_name: "Example Grill", primary_color: "#1898CF" } },
        headers: headers_for(company_a), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "branding")).to include("display_name" => "Example Grill", "primary_color" => "#1898cf")

      patch client_path("/branding"), params: { branding: { display_name: "Taken over" } }, headers: headers_for(company_b), as: :json
      expect(response).to have_http_status(:forbidden)
      put client_path("/help_contacts"), params: { help_contacts: [ contact ] }, headers: headers_for(company_b), as: :json
      expect(response).to have_http_status(:forbidden)
      post client_path("/logo"), params: { file: logo_upload(png_logo) }, headers: headers_for(company_b)
      expect(response).to have_http_status(:forbidden)
      get client_path, headers: headers_for(company_b)
      expect(response).to have_http_status(:forbidden)

      expect(company_b.reload.branding).to eq({})
      expect(company_b.help_contacts).to be_empty
      expect(company_b.brand_logo_storage_key).to be_nil
    end

    it "keeps clients out of the staff endpoint and staff out of the client endpoint" do
      act_as(client_a)
      get admin_path, headers: headers_for(company_a)
      expect(response).to have_http_status(:forbidden)

      act_as(staff)
      get client_path, headers: headers_for(company_a)
      expect(response).to have_http_status(:forbidden)
    end

    it "lets staff with client administration change any client they can access" do
      act_as(staff)

      [ company_a, company_b ].each do |company|
        put admin_path("/help_contacts"), params: { help_contacts: [ contact ] }, headers: headers_for(company), as: :json
        expect(response).to have_http_status(:ok)
        expect(company.help_contacts.reload.map(&:name)).to eq([ "Avery Example" ])
      end
    end

    it "refuses staff without client administration" do
      act_as(accountant)

      get admin_path, headers: headers_for(company_a)
      expect(response).to have_http_status(:forbidden)
      patch admin_path("/branding"), params: { branding: { display_name: "Nope" } }, headers: headers_for(company_a), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(company_a.reload.branding).to eq({})
    end

    it "refuses a client user whose access ends before the save" do
      act_as(client_a)
      # The user is deactivated after the request passed its first checks.
      allow(User).to receive(:lock).and_wrap_original do |original|
        User.where(id: client_a.id).update_all(active: false)
        original.call
      end

      patch client_path("/branding"), params: { branding: { display_name: "Late save" } }, headers: headers_for(company_a), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(company_a.reload.branding).to eq({})
    end
  end

  describe "branding" do
    before { act_as(client_a) }

    it "saves, clears and audits every change" do
      patch client_path("/branding"), params: { branding: {
        display_name: "  Example   Grill ", app_name: "Grill Pay", primary_color: "#1898CF", accent_color: "#FADF06", show_main_phone: false
      } }, headers: headers_for(company_a), as: :json

      expect(response).to have_http_status(:ok)
      expect(company_a.reload.branding).to eq(
        "display_name" => "Example Grill", "app_name" => "Grill Pay", "primary_color" => "#1898cf",
        "accent_color" => "#fadf06", "show_main_phone" => false
      )
      audit = AuditLog.where(action: "employee_app_settings#update_branding").last
      expect(audit).to have_attributes(company_id: company_a.id, user_id: client_a.id, record_type: "companies", record_id: company_a.id)
      expect(audit.metadata["changed_fields"]).to match_array(%w[display_name app_name primary_color accent_color show_main_phone])
      expect(audit.metadata["after_values"]).to include("app_name" => "Grill Pay")

      patch client_path("/branding"), params: { branding: { accent_color: "", show_main_phone: true } }, headers: headers_for(company_a), as: :json
      expect(company_a.reload.branding.keys).to match_array(%w[display_name app_name primary_color])
      expect(AuditLog.where(action: "employee_app_settings#update_branding").count).to eq(2)
    end

    it "refuses invalid values without saving" do
      patch client_path("/branding"), params: { branding: { primary_color: "blue", app_name: "x" * 31 } }, headers: headers_for(company_a), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["details"].join).to include("primary_color", "app_name")
      expect(company_a.reload.branding).to eq({})
      expect(AuditLog.where(action: "employee_app_settings#update_branding")).to be_empty
    end
  end

  describe "logo upload" do
    before { act_as(client_a) }

    it "stores a cleaned PNG, serves the preview and replaces the old object" do
      post client_path("/logo"), params: { file: logo_upload(png_logo) }, headers: headers_for(company_a)

      expect(response).to have_http_status(:ok)
      company_a.reload
      first_key = company_a.brand_logo_storage_key
      expect(company_a.brand_logo_content_type).to eq("image/png")
      expect(response.parsed_body.dig("data", "branding", "logo")).to include("content_type" => "image/png", "digest" => company_a.brand_logo_digest)
      expect(AuditLog.where(action: "employee_app_settings#upload_logo").count).to eq(1)

      get client_path("/logo"), headers: headers_for(company_a)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body).not_to include("Jordan Example")
      expect(response.headers["Cache-Control"]).to include("no-store")

      post client_path("/logo"), params: { file: logo_upload(svg_logo, filename: "logo.svg", content_type: "image/svg+xml") }, headers: headers_for(company_a)
      expect(response).to have_http_status(:ok)
      expect(company_a.reload.brand_logo_content_type).to eq("image/svg+xml")
      expect(R2StorageService.new.exists?(first_key)).to be(false)

      delete client_path("/logo"), headers: headers_for(company_a)
      expect(response).to have_http_status(:ok)
      expect(company_a.reload.brand_logo_storage_key).to be_nil
      expect(AuditLog.where(action: "employee_app_settings#remove_logo").count).to eq(1)
    end

    it "refuses the wrong type, an oversized file and an unsafe SVG" do
      [
        logo_upload("\xFF\xD8\xFF\xE0jpeg".b, filename: "logo.png"),
        logo_upload(png_logo + ("\x00".b * 1.megabyte)),
        logo_upload(svg_logo("<script>alert(1)</script>"), filename: "logo.svg", content_type: "image/svg+xml")
      ].each do |file|
        post client_path("/logo"), params: { file: file }, headers: headers_for(company_a)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to be_present
      end
      expect(company_a.reload.brand_logo_storage_key).to be_nil
      expect(Dir.glob(R2StorageService::LOCAL_STORAGE_ROOT.join("**/*")).select { |path| File.file?(path) }).to be_empty
    end
  end

  describe "Help contacts" do
    before { act_as(client_a) }

    it "replaces the list in the given order and audits it" do
      second = { name: "Riley Example", role: "Owner", email: "riley@example.test" }
      put client_path("/help_contacts"), params: { help_contacts: [ second, contact ] }, headers: headers_for(company_a), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "help_contacts").pluck("name")).to eq([ "Riley Example", "Avery Example" ])
      expect(company_a.help_contacts.reload.map(&:position)).to eq([ 1, 2 ])

      put client_path("/help_contacts"), params: { help_contacts: [ contact ] }, headers: headers_for(company_a), as: :json
      expect(company_a.help_contacts.reload.map(&:name)).to eq([ "Avery Example" ])
      audit = AuditLog.where(action: "employee_app_settings#update_help_contacts").last
      expect(audit.metadata.dig("before_values", "help_contacts").size).to eq(2)
      expect(audit.metadata.dig("after_values", "help_contacts").size).to eq(1)

      put client_path("/help_contacts"), params: { help_contacts: [] }, headers: headers_for(company_a), as: :json
      expect(response).to have_http_status(:ok)
      expect(company_a.help_contacts.reload).to be_empty
    end

    it "refuses more than five, unreachable contacts and texting without a phone, keeping the saved list" do
      put client_path("/help_contacts"), params: { help_contacts: [ contact ] }, headers: headers_for(company_a), as: :json

      put client_path("/help_contacts"), params: { help_contacts: Array.new(6) { contact } }, headers: headers_for(company_a), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("up to 5")

      put client_path("/help_contacts"), params: { help_contacts: [ contact, { name: "No Way To Reach" }, { name: "Bad Phone", phone: "call me" } ] },
        headers: headers_for(company_a), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      details = response.parsed_body.dig("details", "help_contacts")
      expect(details.keys).to eq(%w[1 2])
      expect(details["1"].join).to include("phone number or an email")

      expect(company_a.help_contacts.reload.map(&:name)).to eq([ "Avery Example" ])
      expect(CompanyHelpContact.new(company: company_a, position: 1, name: "Email only", email: "a@example.test", text_ok: true).tap(&:valid?).text_ok).to be(false)
    end
  end

  describe "public tenant branding" do
    before do
      enable_subdomain(company_a)
      act_as(client_a)
      patch client_path("/branding"), params: { branding: { display_name: "Example Grill", app_name: "Grill Pay", primary_color: "#1898CF" } },
        headers: headers_for(company_a), as: :json
      put client_path("/help_contacts"), params: { help_contacts: [ contact ] }, headers: headers_for(company_a), as: :json
      post client_path("/logo"), params: { file: logo_upload(png_logo) }, headers: headers_for(company_a)
    end

    it "serves the new values and the main phone, never Help contacts or storage details" do
      get "/api/v1/public/tenant_branding", params: { slug: "example-grill" }

      body = response.parsed_body
      digest = company_a.reload.brand_logo_digest
      expect(body).to eq(
        "name" => "Example Grill", "app_name" => "Grill Pay", "primary_color" => "#1898cf", "accent_color" => nil,
        "logo_url" => "http://www.example.com/api/v1/public/tenant_branding/logo/example-grill/#{digest}.png",
        "main_phone" => "671-555-0100"
      )
      raw = response.body
      [ "Avery Example", "avery@example.test", "671-555-0111", "General manager", company_a.brand_logo_storage_key,
        company_a.brand_logo_sha256, "tenant-brand" ].each do |secret|
        expect(raw).not_to include(secret)
      end
    end

    it "hides the main phone when the client turns it off" do
      patch client_path("/branding"), params: { branding: { show_main_phone: false } }, headers: headers_for(company_a), as: :json
      get "/api/v1/public/tenant_branding", params: { slug: "example-grill" }
      expect(response.parsed_body["main_phone"]).to be_nil
    end

    it "serves the logo by fingerprint with safe, cacheable headers" do
      digest = company_a.reload.brand_logo_digest
      get "/api/v1/public/tenant_branding/logo/example-grill/#{digest}.png"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[public max-age=31536000 immutable])
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Cross-Origin-Resource-Policy"]).to eq("cross-origin")
      expect(response.headers["Content-Security-Policy"]).to include("default-src 'none'", "sandbox")
      expect(response.headers["Set-Cookie"]).to be_nil

      get "/api/v1/public/tenant_branding/logo/example-grill/#{'0' * 16}.png"
      expect(response).to have_http_status(:not_found)
      get "/api/v1/public/tenant_branding/logo/example-grill/#{digest}.svg"
      expect(response).to have_http_status(:not_found)
    end

    it "stops serving the logo once the subdomain is off" do
      digest = company_a.reload.brand_logo_digest
      company_a.client_operating_profiles.update_all(options: { subdomain_enabled: false })
      TenantSubdomainRegistry.invalidate!

      get "/api/v1/public/tenant_branding/logo/example-grill/#{digest}.png"
      expect(response).to have_http_status(:not_found)
    end
  end
end
