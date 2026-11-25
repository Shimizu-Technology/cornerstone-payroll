# frozen_string_literal: true

require "rails_helper"

# Demo and live never mix in one login, with real token verification: a demo
# client identity can't take over live employee access (or the reverse), and
# it works only while its address is allow-listed and it holds a grant.
RSpec.describe "Demo identity boundary", type: :request do
  include EmployeeLinkHelpers

  let(:allowed) { "reviewer+manager@demo-mail.example" }
  let(:organization) { create(:organization) }
  let(:live) { create(:company, organization: organization, name: "Live Grill") }
  let(:demo) { create_demo_company(organization: organization) }
  let(:admin) { create(:user, role: :admin, company: live, organization: organization) }
  let(:demo_login) do
    create(:user, role: :client, company: demo, organization: organization, email: allowed, name: "Jordan Reyes",
      clerk_id: "user_demo").tap { |user| CompanyAssignment.create!(user: user, company: demo) }
  end
  let(:live_login) do
    create(:user, role: :client, company: live, organization: organization, email: "jordan@client.example", name: "Jordan Reyes",
      clerk_id: "user_live").tap { |user| CompanyAssignment.create!(user: user, company: live) }
  end

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = allowed
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  before { enable_employee_app!(live) }

  def employee_at(company)
    create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", email: nil, date_of_birth: Date.new(1992, 6, 30))
  end

  def claim(subject, employee, code, ssn_last4: employee.ssn_digits.last(4))
    post "/api/v1/employee/links/claim", params: activation_params(employee, code: code, ssn_last4: ssn_last4).except(:email).to_json,
      headers: bearer(subject, fva: [ 0, 0 ], two_factor_enabled: true).merge("CONTENT_TYPE" => "application/json")
  end

  def untouched(link)
    link.reload.slice(:status, :user_id, :failed_activation_attempts, :activation_locked_at)
  end

  describe "employee links" do
    it "never lets a demo login claim a live company's invite, and leaves the live link untouched" do
      employee = employee_at(live)
      invite = invite!(employee, actor: admin, delivery: "code")
      demo_login
      before = untouched(invite.link)

      claim("user_demo", employee, invite.code, ssn_last4: "0000")
      expect(response).to have_http_status(:not_found)
      claim("user_demo", employee, invite.code)
      expect(response).to have_http_status(:not_found)
      expect(untouched(invite.link)).to eq(before)
      expect(AuditLog.where(company_id: live.id, action: "employee_links#activation_failed")).to be_empty

      live_login
      claim("user_live", employee, invite.code)
      expect(response).to have_http_status(:created)
      expect(invite.link.reload).to have_attributes(status: "active", user_id: live_login.id)
    end

    # A demo company holds no employee links (EmployeeAccountLink requires
    # live payroll); the boundary would refuse one anyway.
    it "never opens a demo company's link to a live login" do
      expect(EmployeeAccountLink.new(user: live_login, company: demo, employee: employee_at(demo), status: "invited")).not_to be_valid
      expect(EmployeeLinks.demo_boundary_allows?(live_login, demo)).to be(false)
      expect(EmployeeLinks.demo_boundary_allows?(admin, demo)).to be(false)
      expect(EmployeeLinks.demo_boundary_allows?(demo_login, demo)).to be(true)
      expect(EmployeeLinks.demo_boundary_allows?(demo_login, live)).to be(false)
      expect(EmployeeLinks.demo_boundary_allows?(live_login, live)).to be(true)
    end

    it "won't list or open a live link that a demo login holds" do
      live_login
      crossing = EmployeeAccountLink.create!(user: demo_login, company: live, employee: employee_at(live), status: "active")
      own = EmployeeAccountLink.create!(user: live_login, company: live, employee: employee_at(live), status: "active")

      get "/api/v1/employee/links", headers: bearer("user_demo")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("links")).to be_empty
      get "/api/v1/employee/context", headers: bearer("user_demo").merge("X-Employee-Link-Id" => crossing.id.to_s)
      expect(response).to have_http_status(:not_found)

      get "/api/v1/employee/links", headers: bearer("user_live")
      expect(response.parsed_body.fetch("links").map { |link| link["id"] }).to eq([ own.id ])
      get "/api/v1/employee/context", headers: bearer("user_live").merge("X-Employee-Link-Id" => own.id.to_s)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "live eligibility from the home company" do
    it "keeps live employee access for a live login with a leftover demo grant, and still refuses demo links" do
      live_login
      CompanyAssignment.insert_all!([ { user_id: live_login.id, company_id: demo.id, expires_at: 1.day.ago,
        created_at: Time.current, updated_at: Time.current } ])
      expect(DemoOutbound.demo_company_for(User.find(live_login.id))).to be_nil
      expect(EmployeeLinks.demo_boundary_allows?(live_login, live)).to be(true)
      expect(EmployeeLinks.demo_boundary_allows?(live_login, demo)).to be(false)

      employee = employee_at(live)
      invite = invite!(employee, actor: admin, delivery: "code")
      claim("user_live", employee, invite.code)
      expect(response).to have_http_status(:created)
      get "/api/v1/employee/links", headers: bearer("user_live")
      expect(response.parsed_body.fetch("links").map { |link| link["id"] }).to eq([ invite.link.id ])
    end

    it "drops an expired demo grant when a staff login becomes a client on the Users screen" do
      accountant = create(:user, role: :accountant, company: live, organization: organization, email: "former-staff@firm.example")
      CompanyAssignment.create!(user: accountant, company: live)
      CompanyAssignment.create!(user: accountant, company: demo).update_columns(expires_at: 1.day.ago)
      admin.update!(clerk_id: "user_admin")

      patch "/api/v1/admin/users/#{accountant.id}", params: { user: { role: "client", company_ids: [ live.id ] } }.to_json,
        headers: bearer("user_admin", fva: [ 0, 0 ], two_factor_enabled: true).merge("CONTENT_TYPE" => "application/json")
      expect(response).to have_http_status(:ok), response.body
      expect(accountant.reload.company_assignments.pluck(:company_id)).to eq([ live.id ])
      expect(EmployeeLinks.demo_boundary_allows?(accountant, live)).to be(true)
    end

    it "ignores an inactive demo company when deciding a login's demo ties" do
      live_login
      CompanyAssignment.insert_all!([ { user_id: live_login.id, company_id: demo.id, created_at: Time.current, updated_at: Time.current } ])
      expect(DemoOutbound.demo_company_for(User.find(live_login.id))).to eq(demo)
      demo.update_columns(active: false)
      expect(DemoOutbound.demo_company_for(User.find(live_login.id))).to be_nil
    end
  end

  describe "the under-lock check" do
    it "refuses a link that changed sides before the lock without counting the attempt" do
      employee = employee_at(live)
      invite = invite!(employee, actor: admin, delivery: "code")
      before = untouched(invite.link)
      answers = [ true, false ]
      outcome = EmployeeLinks::Verify.call(token: nil, code: invite.code, date_of_birth: employee.date_of_birth.iso8601,
        ssn_last4: "0000", admit: ->(_link) { answers.shift }) { |link| link }
      expect(outcome).to be_nil
      expect(answers).to be_empty
      expect(untouched(invite.link)).to eq(before)
      expect(AuditLog.where(company_id: live.id, action: "employee_links#activation_failed")).to be_empty
    end
  end

  describe "/auth/me" do
    it "counts only the links the login can open" do
      live_login
      EmployeeAccountLink.create!(user: demo_login, company: live, employee: employee_at(live), status: "active")
      EmployeeAccountLink.create!(user: live_login, company: live, employee: employee_at(live), status: "active")

      get "/api/v1/auth/me", headers: bearer("user_demo")
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("roles", "employee_links_count")).to eq(0)
      get "/api/v1/auth/me", headers: bearer("user_live")
      expect(response.parsed_body.dig("roles", "employee_links_count")).to eq(1)
    end
  end

  describe "access at sign-in" do
    def companies_status
      get "/api/v1/companies", headers: bearer("user_demo")
      response.status
    end

    it "closes a demo client login as soon as its address leaves the allow-list" do
      demo_login
      expect(companies_status).to eq(200)
      expect(response.parsed_body.fetch("companies").map { |company| company["id"] }).to eq([ demo.id ])

      ENV[DemoOutbound::ENV_KEY] = "someone-else@demo-mail.example"
      expect(companies_status).to eq(401)
      expect(User.find(demo_login.id).accessible_company_ids).to be_empty
    end

    it "needs an explicit grant to an active, ready demo company, with no home-company fallback" do
      demo_login
      CompanyAssignment.where(user: demo_login).delete_all
      expect(companies_status).to eq(401)
      expect(User.find(demo_login.id).accessible_company_ids).to be_empty

      CompanyAssignment.create!(user: demo_login, company: demo)
      expect(companies_status).to eq(200)
      demo.update_columns(migration_rehearsal_status: "pending")
      expect(companies_status).to eq(401)
      demo.update_columns(migration_rehearsal_status: "ready", active: false)
      expect(companies_status).to eq(401)
      demo.update_columns(active: true)
      CompanyAssignment.where(user: demo_login).update_all(expires_at: 1.minute.ago)
      expect(companies_status).to eq(401)
    end
  end
end
