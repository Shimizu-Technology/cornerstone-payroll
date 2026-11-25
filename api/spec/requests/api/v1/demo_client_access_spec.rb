# frozen_string_literal: true

require "rails_helper"
require "rake"

# Staff and client access to a demo company: staff work it the normal way,
# its client logins are allow-listed and see only demo companies, and live
# client logins never see one.
RSpec.describe "Demo company staff and client access", type: :request do
  let(:manager_email) { "reviewer+manager@demo-mail.example" }
  let(:user_email) { "reviewer+client@demo-mail.example" }
  let(:organization) { create(:organization) }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:demo) { create_demo_company(organization: organization) }
  let!(:catering) { create_demo_company(organization: organization, name: "Harbor Finch Catering", fixture_key: "harbor-finch-catering") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin") }
  let!(:accountant) { create(:user, company: live, organization: organization, role: "accountant") }
  let!(:live_client) { create(:user, company: live, organization: organization, role: "client", email: "owner@client.example") }

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = "#{manager_email},#{user_email}"
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  def demo_client(email: manager_email, name: "Maren Fable")
    create(:user, company: demo, organization: organization, role: "client", email: email, name: name).tap do |user|
      CompanyAssignment.create!(user: user, company: demo)
    end
  end

  def sign_in(user)
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(user.id) }
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(user.id)
  end

  describe "client logins on a demo company" do
    it "saves only allow-listed addresses and never a practice login" do
      expect(build(:user, company: demo, organization: organization, role: "client", email: manager_email)).to be_valid
      expect(build(:user, company: demo, organization: organization, role: "client", email: "someone@client.example")).not_to be_valid
      expect(build(:user, company: demo, organization: organization, role: "client", email: manager_email, practice_company: demo)).not_to be_valid
    end

    it "keeps demo logins on demo companies and live logins on live ones" do
      maren = demo_client
      expect(CompanyAssignment.new(user: maren, company: live)).not_to be_valid
      expect(CompanyAssignment.new(user: maren, company: catering)).to be_valid
      expect(CompanyAssignment.new(user: live_client, company: demo)).not_to be_valid
      expect(CompanyAssignment.new(user: accountant, company: demo)).to be_valid
      expect(CompanyAssignment.new(user: accountant, company: demo, workspace_access_level: "operator")).not_to be_valid
    end

    it "never widens access through a stray assignment or the home-company fallback" do
      maren = demo_client
      CompanyAssignment.insert_all!([ { user_id: maren.id, company_id: live.id, created_at: Time.current, updated_at: Time.current } ])
      CompanyAssignment.insert_all!([ { user_id: live_client.id, company_id: demo.id, created_at: Time.current, updated_at: Time.current } ])
      expect(User.find(maren.id).accessible_company_ids).to contain_exactly(demo.id)
      expect(User.find(live_client.id).accessible_company_ids).to contain_exactly(live.id)

      unassigned = create(:user, company: demo, organization: organization, role: "client", email: user_email)
      expect(unassigned.accessible_company_ids).to eq([ demo.id ])
    end
  end

  describe "the client portal" do
    let!(:demo_employee) { create(:employee, company: demo, department: create(:department, company: demo), first_name: "Robin", last_name: "Lantern") }
    let!(:live_employee) { create(:employee, company: live, department: create(:department, company: live), first_name: "Real", last_name: "Person") }

    it "shows a demo client only its demo company, like an ordinary client" do
      maren = demo_client
      sign_in(maren)
      get "/api/v1/companies"
      companies = response.parsed_body.fetch("companies")
      expect(companies.map { |company| company["id"] }).to eq([ demo.id ])
      expect(companies.first).to include("test_workspace" => false, "payroll_environment" => "live")
      expect(response.body).not_to match(/demo|practice copy|test workspace/i)

      get "/api/v1/client/employees", headers: { "X-Company-Id" => demo.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("Lantern")
      expect(response.body).not_to match(/demo|practice copy|test workspace/i)

      get "/api/v1/client/employees", headers: { "X-Company-Id" => live.id.to_s }
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("Person")
    end

    it "never shows a live client a demo company" do
      sign_in(live_client)
      get "/api/v1/companies"
      expect(response.parsed_body.fetch("companies").map { |company| company["id"] }).to eq([ live.id ])
      get "/api/v1/client/employees", headers: { "X-Company-Id" => demo.id.to_s }
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("Lantern")
    end

    it "gives the manager and the client user the same client rights and no staff routes" do
      [ demo_client, demo_client(email: user_email, name: "Tessa Vale") ].each do |persona|
        sign_in(persona)
        get "/api/v1/client/employees", headers: { "X-Company-Id" => demo.id.to_s }
        expect(response).to have_http_status(:ok)
        get "/api/v1/admin/employees", headers: { "X-Company-Id" => demo.id.to_s }
        expect(response).to have_http_status(:forbidden)
        get "/api/v1/admin/companies"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "staff" do
    it "assigns an accountant to a demo the normal way, with no workspace level" do
      sign_in(admin)
      post "/api/v1/admin/company_assignments", params: { company_assignment: { user_id: accountant.id, company_id: demo.id } },
        headers: { "X-Company-Id" => demo.id.to_s }
      expect(response).to have_http_status(:created).or have_http_status(:ok)
      assignment = CompanyAssignment.find_by!(user: accountant, company: demo)
      expect(assignment.workspace_access_level).to be_nil
      expect(User.find(accountant.id).accessible_company_ids).to include(demo.id)
    end

    it "leaves normal staff workflows open in a demo and closes only what leaves the building" do
      open = {
        "api/v1/admin/pay_periods" => %w[run_payroll approve unapprove commit void correct_pay_date update],
        "api/v1/admin/checks" => %w[batch_pdf mark_printed mark_all_printed void reprint show preview_pdf],
        "api/v1/admin/employees" => %w[create update],
        "api/v1/admin/employee_contact_changes" => %w[index update confirm],
        "api/v1/admin/employee_app_settings" => %w[show update],
        "api/v1/admin/reports" => %w[w2_gu w2_gu_mark_ready w3ss_pdf w2_gu_employee_copies w2_gu_copy_1_drt payroll_register form_941_gu]
      }
      open.each do |controller_path, actions|
        actions.each do |action|
          expect(TestWorkspaceSafetyPolicy.blocked?(controller_path: controller_path, action_name: action, request_method: "POST", demo: true))
            .to be(false), "#{controller_path}##{action} is blocked for a demo"
        end
      end
      closed = { "api/v1/admin/reports" => %w[w2_gu_efw2 form_1099_pub1220], "api/v1/admin/pay_periods" => %w[generate_fit_check],
                 "api/v1/admin/payroll_filing_records" => %w[create_event], "api/v1/admin/invoices" => %w[create] }
      closed.each do |controller_path, actions|
        actions.each do |action|
          expect(TestWorkspaceSafetyPolicy.blocked?(controller_path: controller_path, action_name: action, request_method: "POST", demo: true)).to be(true)
        end
      end
      expect(TestWorkspaceAccessPolicy.allowed?(user: accountant, company: demo, request_method: "POST", capability: :manage_client_configuration)).to be(true)
      expect(Company::DEMO_UNAVAILABLE_MESSAGE).not_to match(/demo/i)
    end

    it "creates a client login for a demo company on that company" do
      sign_in(admin)
      allow_any_instance_of(PayrollInvitation).to receive(:send_invite).and_return(success: false, error: "not sent in tests")
      post "/api/v1/admin/users", params: { user: { email: manager_email, name: "Maren Fable", role: "client", company_ids: [ demo.id ] } }
      expect(response).to have_http_status(:created), response.body
      user = User.find_by!(email: manager_email)
      expect(user.company).to eq(demo)
      expect(user.accessible_company_ids).to eq([ demo.id ])

      post "/api/v1/admin/users", params: { user: { email: user_email, role: "client", company_ids: [ demo.id, live.id ] } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to match(/demo/i)
    end

    it "keeps a demo client login out of the practice-login move" do
      maren = demo_client
      sandbox = create(:company, organization: organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox",
        migration_source_company: live, migration_rehearsal_status: "ready")
      expect { TestWorkspace::MovePracticeLogin.new(user: maren, target_company: sandbox, actor: admin, activate: true).call }
        .to raise_error(TestWorkspace::MovePracticeLogin::Refused)
      expect(maren.reload.company).to eq(demo)
      expect(maren.practice_company_id).to be_nil
      expect(maren.accessible_company_ids).to eq([ demo.id ])
    end
  end

  describe "binding a demo client login" do
    let(:provider) { instance_double(ClerkInvitationService, configured?: true) }
    let(:nonce) { SecureRandom.hex(32) }

    def pending_login(email)
      demo_client(email: email).tap do |user|
        user.update!(invitation_status: "pending", clerk_id: "pending_#{SecureRandom.uuid}", clerk_invitation_id: "inv_demo",
          invite_nonce_digest: Digest::SHA256.hexdigest(nonce), invite_nonce_expires_at: 1.day.from_now)
      end
    end

    def clerk_user(user, primary)
      { "id" => "user_demo", "public_metadata" => { "payroll_user_id" => user.id, "payroll_invite_nonce" => nonce },
        "primary_email_address_id" => "e1",
        "email_addresses" => [ { "id" => "e1", "email_address" => primary, "verification" => { "status" => "verified", "strategy" => "ticket" } } ] }
    end

    it "binds an allow-listed demo client end to end and refuses a different primary address" do
      maren = pending_login(manager_email)
      allow(provider).to receive(:invitation_status).with("inv_demo").and_return("accepted")
      allow(provider).to receive(:fetch_user).with("user_demo").and_return(clerk_user(maren, "someone@client.example"))
      request = ActionDispatch::TestRequest.create
      expect(PayrollInvitation.new(clerk: provider).bind_from_metadata("user_demo", request: request)).to be_nil

      allow(provider).to receive(:fetch_user).with("user_demo").and_return(clerk_user(maren, manager_email))
      expect(PayrollInvitation.new(clerk: provider).bind_from_metadata("user_demo", request: request)).to eq(maren)
      expect(maren.reload).to have_attributes(clerk_id: "user_demo", invitation_status: "accepted")
      expect(maren.accessible_company_ids).to eq([ demo.id ])
    end
  end

  describe "rake demo:invite_clients" do
    let(:invitation) { instance_double(PayrollInvitation) }

    def invite(manager: manager_email, user: user_email)
      DemoCompany::InviteClients.new(organization: organization, actor: admin, manager_email: manager, user_email: user, invitation: invitation).call
    end

    before { allow(UserInviteEmailService).to receive(:send_invite).and_return(true) }

    it "invites both personas through the normal invitation once, and refuses addresses off the allow-list" do
      expect { invite(user: "someone@client.example") }.to raise_error(DemoCompany::InviteClients::Refused, /allow-list/)
      expect(User.where(company: demo)).to be_empty

      allow(invitation).to receive(:send_invite) do |login, **|
        login.update!(clerk_invitation_id: "inv_#{login.id}")
        { success: true, url: "https://payroll.example.test/login" }
      end
      outcomes = invite
      expect(outcomes.map(&:status)).to eq(%w[invited invited])
      expect(User.where(company: demo).order(:name).pluck(:name, :role)).to eq([ [ "Maren Fable", "client" ], [ "Tessa Vale", "client" ] ])
      expect(CompanyAssignment.where(company: demo).count).to eq(2)

      expect(invite.map(&:status)).to eq(%w[already_invited already_invited])
      expect(invitation).to have_received(:send_invite).twice
    end

    it "runs as a rake task and prints domains, not addresses" do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:invite_clients")
      task = Rake::Task["demo:invite_clients"]
      task.reenable
      allow(PayrollInvitation).to receive(:new).and_return(invitation)
      allow(invitation).to receive(:send_invite) { |login, **| login.update!(clerk_invitation_id: "inv_#{login.id}") && { success: true, url: "u" } }
      saved = ENV.to_h.slice("ORGANIZATION_ID", "ACTOR_ID", "MANAGER_EMAIL", "USER_EMAIL")
      ENV.update("ORGANIZATION_ID" => organization.id.to_s, "ACTOR_ID" => admin.id.to_s, "MANAGER_EMAIL" => manager_email, "USER_EMAIL" => user_email)
      expect { task.invoke }.to output(/OK    demo:invite_clients demo-mail\.example invited/).to_stdout
      expect { task.reenable; task.invoke }.not_to output(/reviewer\+/).to_stdout
    ensure
      %w[ORGANIZATION_ID ACTOR_ID MANAGER_EMAIL USER_EMAIL].each { |key| ENV[key] = saved&.dig(key) }
    end
  end
end
