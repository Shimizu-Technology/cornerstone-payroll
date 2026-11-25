# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

# The employee side of a demo company (demo plan D6/D7), end to end through
# the API with real token verification and the RLS guard in raise mode: it
# works like a real client's, stays on its side of the demo boundary and
# emails only allow-listed addresses. Only R2 and Clerk's Backend API are
# doubles.
RSpec.describe "Demo employee journey", :portal_notifications, type: :request do
  include EmployeeLinkHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:robin_email) { "reviewer+hf-emp1@demo-mail.example" }
  let(:kit_email) { "reviewer+hf-emp6@demo-mail.example" }
  let(:manager_email) { "reviewer+manager@demo-mail.example" }
  let(:outside_email) { "someone@client.example" }
  let(:organization) { create(:organization) }
  let!(:live) { create(:company, organization: organization, name: "Live Grill") }
  let!(:kitchen) { create_demo_company(organization: organization, subdomain_slug: "harborfinch", ein: "07-1234567") }
  let!(:catering) do
    create_demo_company(organization: organization, name: "Harbor Finch Catering", fixture_key: DemoCompany::Roster::CATERING,
      subdomain_slug: "harborfinch-catering")
  end
  let!(:staff) { create(:user, role: :admin, company: live, organization: organization, clerk_id: "user_staff") }
  let(:robin) do
    create(:employee, company: kitchen, first_name: "Robin", last_name: "Lantern", email: robin_email,
      date_of_birth: Date.new(1994, 3, 14), ssn_encrypted: "900-01-1001")
  end
  let(:stored) { {} }
  let(:storage) { instance_double(R2StorageService) }

  around do |example|
    saved = ENV.to_h.slice(DemoOutbound::ENV_KEY, "EMPLOYEE_PORTAL_URL")
    ENV[DemoOutbound::ENV_KEY] = [ robin_email, kit_email, manager_email ].join(",")
    ENV["EMPLOYEE_PORTAL_URL"] = EmployeeLinkHelpers::APP_URL
    example.run
  ensure
    [ DemoOutbound::ENV_KEY, "EMPLOYEE_PORTAL_URL" ].each { |key| ENV[key] = saved[key] }
  end

  before do
    DeliveryDisclosures::DraftSeeds.seed!
    [ kitchen, catering, live ].each { |company| turn_on_employee_app!(company) }
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) { |key, bytes, **| stored[key] = bytes.dup.b }
    allow(storage).to receive(:download) { |key| stored[key] }
    allow(storage).to receive(:delete) { |key| stored.delete(key) }
  end

  # What M4-9d's switch will set for an approved demo; built directly here.
  def turn_on_employee_app!(company)
    features = %w[stubs tax_forms profile_requests delivery_consent].index_with(true)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today - 30, version: 1, offering: "payroll_portals", hours_source: "manual",
      client_portal_enabled: true, employee_portal_enabled: true, options: { "employee_portal" => { "features" => features } }
    )
    TenantSubdomainRegistry.invalidate!
  end

  def staff_headers(company = kitchen)
    bearer("user_staff", fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => company.id.to_s)
  end

  def employee_headers(link, subject: link.user.clerk_id)
    bearer(subject).merge("X-Employee-Link-Id" => link.id.to_s)
  end

  def invite_by_email!(employee)
    post "/api/v1/admin/employees/#{employee.id}/employee_app/invite", headers: staff_headers(employee.company),
      params: { delivery: "email" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    EmployeeAccountLink.where(employee: employee).order(:id).last
  end

  def invite_token
    captured_portal_emails.last.values_at(:text, :html).join[/token=([A-Za-z0-9_-]+)/, 1]
  end

  def sign_up!(employee, token, email, subject)
    post_activation(activation_params(employee, token: token, email: email))
    expect_sign_up_started
    expect(clerk_invitations.last[:email]).to eq(email)
    accept_clerk_invitation!(subject)
    get "/api/v1/auth/me", headers: bearer(subject)
    expect(response).to have_http_status(:ok), response.body
    User.find_by!(clerk_id: subject)
  end

  def committed_period(company, pay_date)
    create(:pay_period, :committed, company: company, start_date: pay_date - 13, end_date: pay_date - 6, pay_date: pay_date,
      committed_at: pay_date.to_time - 2.days)
  end

  def pay!(employee, pay_date)
    period = PayPeriod.find_by(company: employee.company, pay_date: pay_date) || committed_period(employee.company, pay_date)
    create(:payroll_item, company: employee.company, pay_period: period, employee: employee, gross_pay: 2_000, net_pay: 1_600,
      hours_worked: 80, payment_delivery_method: "direct_deposit", withholding_tax: 150, social_security_tax: 124,
      employer_social_security_tax: 124, medicare_tax: 29, employer_medicare_tax: 29, social_security_taxable_wages: 2_000,
      social_security_taxable_tips: 0, medicare_taxable_wages: 2_000, fit_taxable_wages: 2_000)
  end

  def pdf_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ")
  end

  it "runs a demo employee's app end to end like a real client's" do
    with_portal_email do
      # Invite by email, sign up and bind.
      link = invite_by_email!(robin)
      expect(captured_portal_emails.flat_map { |email| email[:to] }).to eq([ robin_email ])
      token = invite_token
      expect(token).to be_present
      worker = sign_up!(robin, token, robin_email, "user_robin")
      expect(worker).to have_attributes(role: "portal_employee", company_id: kitchen.id)
      expect(link.reload).to have_attributes(status: "active", user_id: worker.id, payroll_environment: "migration_rehearsal")
      get "/api/v1/auth/me", headers: bearer("user_robin")
      expect(response.parsed_body.dig("roles", "employee_links_count")).to eq(1)

      get "/api/v1/employee/context", headers: employee_headers(link)
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).not_to match(/demo|practice|test workspace/i)
      get "/api/v1/employee/links", headers: bearer("user_robin")
      expect(response.parsed_body.fetch("links").map { |row| row["company_name"] }).to eq([ "Harbor Finch Kitchen" ])

      # A committed payday posts a frozen stub that reads like a real one.
      item = pay!(robin, PayrollBusinessClock.today - 3)
      perform_enqueued_jobs { PostEmployeePayStubsJob.perform_now }
      document = EmployeeDocument.find_by!(payroll_item: item, status: "posted")
      get "/api/v1/employee/statements", headers: employee_headers(link)
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("statements").map { |row| row["id"] }).to eq([ document.id.to_s ])
      get "/api/v1/employee/statements/#{document.id}/pdf", headers: employee_headers(link)
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to start_with("%PDF")
      expect(pdf_text(response.body)).to include("Harbor Finch Kitchen")
      expect(pdf_text(response.body)).not_to match(/demo|practice|sample|test workspace/i)

      # Consent with the draft disclosure, then a profile change and an address request.
      get "/api/v1/employee/delivery_consents", headers: employee_headers(link)
      expect(response).to have_http_status(:ok), response.body
      disclosure = DeliveryDisclosure.current_for("pay_statements")
      post "/api/v1/employee/delivery_consents", headers: employee_headers(link), as: :json,
        params: { kind: "pay_statements", acknowledged: true, disclosure_version: disclosure.version, disclosure_digest: disclosure.digest }
      expect(response).to have_http_status(:created).or have_http_status(:ok)
      expect(response.body).not_to match(/demo|practice|test workspace/i)

      patch "/api/v1/employee/profile/phone", headers: employee_headers(link), params: { phone: "6715550161" }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(EmployeeContactChangeToConfirm.where(employee: robin)).to exist

      post "/api/v1/employee/address_requests", headers: employee_headers(link), as: :json,
        params: { address: { address_line1: "12 Harbor Finch Way", city: "Hagatna", state: "GU", zip: "96910" } }
      expect(response).to have_http_status(:created), response.body
      request_id = response.parsed_body.dig("address_request", "id")
      manager = create(:user, role: :client, company: kitchen, organization: organization, email: manager_email,
        name: "Maren Fable", clerk_id: "user_maren").tap { |user| CompanyAssignment.create!(user: user, company: kitchen) }
      get "/api/v1/client/employee_change_requests", headers: bearer(manager.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true)
        .merge("X-Company-Id" => kitchen.id.to_s)
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include(request_id.to_s)
      patch "/api/v1/client/employee_change_requests/#{request_id}/approve",
        headers: bearer(manager.clerk_id, fva: [ 0, 0 ], two_factor_enabled: true).merge("X-Company-Id" => kitchen.id.to_s)
      expect(response).to have_http_status(:ok), response.body
      expect(robin.reload.address_line1).to eq("12 Harbor Finch Way")

      get "/api/v1/admin/employee_contact_changes_to_confirm", headers: staff_headers
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("Lantern")

      # Nothing in the journey emailed anyone off the allow-list.
      expect(captured_portal_emails.flat_map { |email| Array(email[:to]) + Array(email[:cc]) + Array(email[:bcc]) }.uniq - [ robin_email, manager_email ]).to be_empty
    end
  end

  it "posts final W-2GU copies for a demo and emails the notice only to an allow-listed address" do
    robin
    alias_less = create(:employee, company: kitchen, first_name: "Avery", last_name: "Sprig", email: outside_email,
      email_verified_at: 1.day.ago, ssn_encrypted: "900-01-1004")
    worker = create(:user, role: :portal_employee, company: kitchen, organization: organization, email: robin_email, clerk_id: "user_robin")
    link = EmployeeAccountLink.create!(user: worker, company: kitchen, employee: robin, status: "active", activated_at: 1.day.ago)
    robin.update!(email_verified_at: 1.day.ago)
    create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000)
    [ robin, alias_less ].each { |person| pay!(person, Date.new(2026, 3, 6)) }

    { "w2_gu" => "cornerstone", "form_1099" => "no_filing" }.each do |filing_type, party|
      put "/api/v1/admin/payroll_filing_responsibilities", headers: staff_headers, as: :json, params: {
        responsibility: { tax_year: 2026, filing_types: [ filing_type ], responsible_party: party, imported_payroll_inclusion: "included" }
      }
      expect(response).to have_http_status(:ok), response.body
    end
    post "/api/v1/admin/reports/w2_gu_preflight", headers: staff_headers, as: :json, params: { year: 2026 }
    post "/api/v1/admin/reports/w2_gu_mark_ready", headers: staff_headers, as: :json, params: { year: 2026, notes: "Year-end review" }
    expect(response).to have_http_status(:ok), response.body

    with_portal_email do
      perform_enqueued_jobs do
        post "/api/v1/admin/employee_tax_forms/post_copies", headers: staff_headers, as: :json, params: { year: 2026 }
        expect(response.status).to be_between(200, 202), response.body
        DispatchEmployeeTaxFormNoticesJob.perform_now
      end
      expect(captured_portal_emails.flat_map { |email| email[:to] }).to eq([ robin_email ])
    end

    get "/api/v1/employee/tax_forms", headers: employee_headers(link)
    expect(response).to have_http_status(:ok), response.body
    form = response.parsed_body.fetch("tax_forms").sole
    get "/api/v1/employee/tax_forms/#{form['id']}/pdf", headers: employee_headers(link)
    expect(response).to have_http_status(:ok)
    text = pdf_text(response.body)
    expect(text).to include("Harbor Finch Kitchen")
    expect(text).not_to match(/demo|practice|sample|not for filing|test workspace/i)
  end

  it "shows a former employee's own history read-only" do
    worker = create(:user, role: :portal_employee, company: kitchen, organization: organization, email: robin_email, clerk_id: "user_robin")
    link = EmployeeAccountLink.create!(user: worker, company: kitchen, employee: robin, status: "former",
      activated_at: 30.days.ago, former_at: 1.day.ago, former_access_until: 1.year.from_now)
    pay!(robin, PayrollBusinessClock.today - 3)
    perform_enqueued_jobs { PostEmployeePayStubsJob.perform_now }

    get "/api/v1/employee/statements", headers: employee_headers(link)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("statements").size).to eq(1)
    patch "/api/v1/employee/profile/phone", headers: employee_headers(link), params: { phone: "6715550161" }, as: :json
    expect(response.status).to be_between(400, 404)
  end

  it "picks between both demo employers for one login" do
    kit_kitchen = create(:employee, company: kitchen, first_name: "Kit", last_name: "Wren", email: kit_email,
      date_of_birth: Date.new(2000, 12, 12), ssn_encrypted: "900-01-1008")
    kit_catering = create(:employee, company: catering, first_name: "Kit", last_name: "Wren", email: kit_email,
      date_of_birth: Date.new(2000, 12, 12), ssn_encrypted: "900-01-1008")

    with_portal_email do
      invite_by_email!(kit_kitchen)
      sign_up!(kit_kitchen, invite_token, kit_email, "user_kit")
    end
    post "/api/v1/admin/employees/#{kit_catering.id}/employee_app/invite", headers: staff_headers(catering),
      params: { delivery: "code" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    code = response.parsed_body.dig("print", "code")
    expect(code).to be_present
    post "/api/v1/employee/links/claim", headers: bearer("user_kit").merge("CONTENT_TYPE" => "application/json"),
      params: activation_params(kit_catering, code: code).except(:email).to_json
    expect(response).to have_http_status(:created), response.body

    get "/api/v1/employee/links", headers: bearer("user_kit")
    expect(response.parsed_body.fetch("links").map { |link| link["company_name"] }).to eq([ "Harbor Finch Kitchen", "Harbor Finch Catering" ])
    EmployeeAccountLink.where(user: User.find_by!(clerk_id: "user_kit")).find_each do |link|
      get "/api/v1/employee/context", headers: employee_headers(link)
      expect(response).to have_http_status(:ok), response.body
    end
  end

  it "serves each demo employer on its own subdomain, and never a practice copy" do
    [ kitchen, catering ].each do |company|
      company.client_operating_profiles.update_all(options: { "subdomain_enabled" => true, "employee_portal" => { "features" => { "stubs" => true } } })
    end
    TenantSubdomainRegistry.invalidate!

    expect(TenantSubdomainRegistry.enabled_origin_company_id("https://harborfinch.shimizu-technology.com")).to eq(kitchen.id)
    expect(TenantSubdomainRegistry.enabled_origin_company_id("https://harborfinch-catering.shimizu-technology.com")).to eq(catering.id)
    expect(EmployeeLinks::AppUrl.origin_for(kitchen)).to eq("https://harborfinch.shimizu-technology.com")
    expect(EmployeeLinks::AppUrl.sign_up_redirect_url(catering)).to eq("https://harborfinch-catering.shimizu-technology.com/sign-up")

    # A practice copy can't hold a slug, and its profile never opens the app.
    sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
      migration_source_company: live, migration_rehearsal_status: "ready")
    sandbox.client_operating_profiles.create!(effective_on: PayrollBusinessClock.today - 30, version: 1, offering: "payroll_portals",
      hours_source: "manual", client_portal_enabled: true, employee_portal_enabled: true, options: { "subdomain_enabled" => true })
    expect(CompanyFeatures.for(sandbox)).to have_attributes(subdomain_enabled?: false, employee_portal_enabled?: false)
  end

  describe "the demo boundary" do
    it "refuses crossing in both directions" do
      live_worker = create(:user, role: :portal_employee, company: live, organization: organization, name: "Robin Lantern",
        email: "robin@live-grill.example", clerk_id: "user_live_robin")
      post "/api/v1/admin/employees/#{robin.id}/employee_app/invite", headers: staff_headers, params: { delivery: "code" }, as: :json
      demo_code = response.parsed_body.dig("print", "code")
      post "/api/v1/employee/links/claim", headers: bearer("user_live_robin").merge("CONTENT_TYPE" => "application/json"),
        params: activation_params(robin, code: demo_code).except(:email).to_json
      expect(response).to have_http_status(:not_found)

      demo_worker = create(:user, role: :portal_employee, company: kitchen, organization: organization, name: "Robin Lantern",
        email: robin_email, clerk_id: "user_robin")
      live_robin = create(:employee, company: live, first_name: "Robin", last_name: "Lantern", date_of_birth: Date.new(1994, 3, 14))
      post "/api/v1/admin/employees/#{live_robin.id}/employee_app/invite", headers: staff_headers(live), params: { delivery: "code" }, as: :json
      live_code = response.parsed_body.dig("print", "code")
      post "/api/v1/employee/links/claim", headers: bearer("user_robin").merge("CONTENT_TYPE" => "application/json"),
        params: activation_params(live_robin, code: live_code).except(:email).to_json
      expect(response).to have_http_status(:not_found)
      expect(EmployeeAccountLink.where(user: [ live_worker, demo_worker ])).to be_empty
    end

    it "keeps a practice copy's employees out of the app, in the model and the database" do
      sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company: live, migration_rehearsal_status: "ready")
      copied = create(:employee, company: sandbox)
      expect(EmployeeAccountLink.new(company: sandbox, employee: copied)).not_to be_valid
      expect(CompanyFeatures.for(sandbox).employee_portal_enabled?).to be(false)
      expect(CompanyFeatures.for(kitchen).employee_portal_enabled?).to be(true)
      expect do
        EmployeeAccountLink.insert_all!([ { company_id: sandbox.id, employee_id: copied.id, payroll_environment: "migration_rehearsal",
          status: "invited", created_at: Time.current, updated_at: Time.current } ])
      end.to raise_error(ActiveRecord::StatementInvalid, /live or demo company/)
    end

    it "never sends invites or sign-ups outside the allow-list" do
      outsider = create(:employee, company: kitchen, first_name: "Avery", last_name: "Sprig", email: outside_email,
        date_of_birth: Date.new(2003, 5, 27))
      with_portal_email do
        post "/api/v1/admin/employees/#{outsider.id}/employee_app/invite", headers: staff_headers, params: { delivery: "email" }, as: :json
        expect(captured_portal_emails).to be_empty

        post "/api/v1/admin/employees/#{outsider.id}/employee_app/invite", headers: staff_headers, params: { delivery: "code" }, as: :json
        code = response.parsed_body.dig("print", "code")
        post_activation(activation_params(outsider, code: code, email: outside_email))
        expect(clerk_invitations).to be_empty
        expect(captured_portal_emails).to be_empty
      end
    end
  end
end
