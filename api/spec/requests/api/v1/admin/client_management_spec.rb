# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin-delegated accountant client management", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company, organization: company.organization) }
  let!(:admin) { create(:user, company: company, role: "admin") }
  let!(:accountant) { create(:user, company: company, role: "accountant") }
  let!(:assignment) { create(:company_assignment, user: accountant, company: company) }
  let!(:other_assignment) { create(:company_assignment, user: accountant, company: other_company) }
  let(:actor) { accountant }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(actor)
  end

  def grant!
    assignment.update!(client_management: true, granted_by: admin)
  end

  def update_grant(value, id: assignment.id, extra: {})
    patch "/api/v1/admin/company_assignments/#{id}", params: { company_assignment: { client_management: value }.merge(extra) }, headers: headers, as: :json
  end

  it "lets an administrator explicitly grant and revoke with attributed before/after audit evidence" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    expiry = 1.day.from_now.change(usec: 0)
    assignment.update!(expires_at: expiry)
    update_grant(true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "client_management")).to be(true)
    expect(assignment.reload.expires_at).to eq(expiry)
    audit = AuditLog.find_by!(action: "company_assignments#client_management_updated", record_id: assignment.id.to_s)
    expect(audit.user_id).to eq(admin.id)
    expect(audit.company_id).to eq(company.id)
    expect(audit.metadata).to include("actor_id" => admin.id, "user_id" => accountant.id, "company_id" => company.id)
    expect(audit.metadata.dig("before_values", "client_management")).to be(false)
    expect(audit.metadata.dig("after_values", "client_management")).to be(true)
    update_grant(false)
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.client_management).to be(false)
    expect(assignment.expires_at).to eq(expiry)
    expect(accountant.can_access_company?(company.id)).to be(true)
  end

  it "rejects self grant by an accountant even with a current grant" do
    grant!
    update_grant(true)
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects a manager granting client management" do
    manager = create(:user, company: company, role: "manager")
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(manager)
    update_grant(true)
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects foreign assignment updates" do
    foreign_company = create(:company)
    foreign_user = create(:user, company: foreign_company, role: "accountant")
    foreign_assignment = create(:company_assignment, user: foreign_user, company: foreign_company)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    update_grant(true, id: foreign_assignment.id)
    expect(response).to have_http_status(:not_found)
    expect(foreign_assignment.reload.client_management).to be(false)
  end

  it "requires a JSON boolean rather than silently casting arbitrary strings" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    update_grant("false")
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects expiry changes without changing membership, grant attribution or audit" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    original = assignment.attributes
    [ 1.day.from_now.iso8601, 1.day.ago.iso8601, nil, "", "not-a-date", false, {} ].each do |expiry|
      [ true, false ].each do |value|
        update_grant(value, extra: { expires_at: expiry })
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to include("cannot change assignment expiry")
        expect(assignment.reload.attributes).to eq(original)
      end
    end
    expect(AuditLog.where(action: "company_assignments#client_management_updated")).to be_empty
  end

  it "revokes an expired inactive accountant without renewing their ordinary access" do
    grant!
    expiry = 1.minute.ago.change(usec: 0)
    assignment.update!(expires_at: expiry)
    accountant.update!(active: false)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    update_grant(false)
    expect(response).to have_http_status(:ok)
    expect(assignment.reload).to have_attributes(client_management: false, expires_at: expiry)
    expect(accountant.can_access_company?(company.id)).to be(false)
    update_grant(true)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("error" => "Validation failed", "details" => include("client_management"))
    expect(assignment.reload).to have_attributes(client_management: false, expires_at: expiry)
  end

  it "does not elevate an assignment through the create endpoint" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    additional = create(:company, organization: company.organization)
    post "/api/v1/admin/company_assignments", params: { company_assignment: {
      user_id: accountant.id, company_id: additional.id, client_management: true
    } }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    expect(CompanyAssignment.find_by!(user: accountant, company: additional).client_management).to be(false)
  end

  it "allows a real client check-settings write only after an explicit grant" do
    patch "/api/v1/admin/companies/check_settings", params: { bank_name: "Synthetic Bank" }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    grant!
    patch "/api/v1/admin/companies/check_settings", params: { bank_name: "Synthetic Bank" }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(company.reload.bank_name).to eq("Synthetic Bank")
    assignment.update!(client_management: false)
    patch "/api/v1/admin/companies/check_settings", params: { bank_name: "Revoked Bank" }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.bank_name).to eq("Synthetic Bank")
  end

  it "reports intake review authority once for an employee page in the selected client" do
    grant!
    create_list(:employee, 3, company: company)
    expect(StaffRolePolicy).to receive(:allowed?).with(accountant, :manage_client_configuration, company: company).once.and_call_original
    get "/api/v1/admin/employees", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").map { |row| row.dig("intake_readiness", "can_review") }).to eq([ true, true, true ])
  end

  it "allows delegated core company edits for the actual resource" do
    grant!
    patch "/api/v1/admin/companies/#{company.id}", params: { company: { name: "Delegated Client" } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(company.reload.name).to eq("Delegated Client")
    expect(accountant.reload.role).to eq("accountant")
  end

  it "does not let a granted header elevate another accessible company's core fields" do
    grant!
    original_name = other_company.name
    patch "/api/v1/admin/companies/#{other_company.id}", params: { company: { name: "Wrong Target" } }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(other_company.reload.name).to eq(original_name)
  end

  it "does not use an ungranted header when check-settings URL targets the granted client" do
    grant!
    patch "/api/v1/admin/companies/check_settings?company_id=#{company.id}", params: { bank_name: "Wrong Header" }, headers: { "X-Company-Id" => other_company.id.to_s }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.bank_name).not_to eq("Wrong Header")
    expect(other_company.reload.bank_name).not_to eq("Wrong Header")
  end

  it "denies the ungranted URL target even with a granted header" do
    grant!
    patch "/api/v1/admin/companies/check_settings?company_id=#{other_company.id}", params: { bank_name: "Wrong Target" }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "denies expired grants at a real endpoint" do
    grant!
    assignment.update!(expires_at: 1.second.ago)
    patch "/api/v1/admin/companies/check_settings", params: { bank_name: "Expired" }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "rechecks a revocation between controller authorization and its locked write" do
    grant!
    allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:check_settings_update_params).and_wrap_original do |method, *args|
      assignment.update!(client_management: false)
      method.call(*args)
    end
    patch "/api/v1/admin/companies/check_settings", params: { bank_name: "Race" }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.bank_name).not_to eq("Race")
  end

  it "cannot use a company_id query to authorize a write against an ungranted header company" do
    grant!
    put "/api/v1/admin/pay_schedule_settings?company_id=#{company.id}", params: { pay_schedule_settings: {} },
      headers: { "X-Company-Id" => other_company.id.to_s }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "rechecks a full company edit when its grant is revoked before the write" do
    grant!
    original_name = company.name
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:company_params).and_wrap_original do |method, *args|
      assignment.update!(client_management: false)
      method.call(*args)
    end
    patch "/api/v1/admin/companies/#{company.id}", params: { company: { name: "Race" } }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(company.reload.name).to eq(original_name)
  end

  it "does not renew or grant access for an inactive accountant" do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    accountant.update!(active: false)
    update_grant(true)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(assignment.reload.client_management).to be(false)
  end

  it "keeps source credentials, technical setup and organization administration role-only" do
    grant!
    source = create(:time_tracking_source, company: company)
    [ [ :put, "/api/v1/admin/time_tracking_sources/#{source.id}/delegation" ],
      [ :delete, "/api/v1/admin/time_tracking_sources/#{source.id}/delegation" ],
      [ :patch, "/api/v1/admin/time_tracking_sources/#{source.id}" ],
      [ :post, "/api/v1/admin/time_tracking_sources" ],
      [ :get, "/api/v1/admin/users" ],
      [ :get, "/api/v1/admin/tax_configs" ],
      [ :post, "/api/v1/admin/payroll_go_live/preview_setup" ] ].each do |verb, path|
      public_send(verb, path, headers: headers, as: :json)
      expect(response).to have_http_status(:forbidden), "#{verb} #{path}: #{response.status}"
    end
    expect(TimeTrackingDelegation.count).to eq(0)
  end

  it "exposes scoped transport while keeping global auth capabilities and role unchanged" do
    grant!
    get "/api/v1/auth/me", headers: headers
    expect(response).to have_http_status(:ok)
    user = response.parsed_body.fetch("user")
    expect(user.fetch("role")).to eq("accountant")
    expect(user.fetch("capabilities")).not_to include("manage_client_configuration", "manage_client_check_settings")
    expect(user.fetch("company_capabilities").fetch(company.id.to_s)).to include("manage_client_configuration", "manage_client_check_settings")
    expect(user.fetch("company_capabilities").fetch(other_company.id.to_s)).not_to include("manage_client_configuration")
    [ "/api/v1/companies", "/api/v1/admin/companies" ].each do |path|
      get path, headers: headers
      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("companies")
      expect(rows.find { |row| row["id"] == company.id }).to include("client_management" => true)
      expect(rows.find { |row| row["id"] == other_company.id }).to include("client_management" => false)
    end
  end

  it "requires an explicit revoke before changing a granted accountant to another role" do
    grant!
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    patch "/api/v1/admin/users/#{accountant.id}", params: { user: { role: "client", company_ids: [ company.id, other_company.id ] } }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(accountant.reload.role).to eq("accountant")
    expect(assignment.reload.client_management).to be(true)
    update_grant(false)
    patch "/api/v1/admin/users/#{accountant.id}", params: { user: { role: "client", company_ids: [ company.id, other_company.id ] } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.client_management).to be(false)
  end

  it "preserves hidden expired grants during an ordinary profile save without renewing them" do
    grant!
    expired_at = 1.minute.ago.change(usec: 0)
    assignment.update!(expires_at: expired_at)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    patch "/api/v1/admin/users/#{accountant.id}", params: { user: { name: "Expired Grant Profile", company_ids: [ other_company.id ] } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assignment.reload).to have_attributes(client_management: true, expires_at: expired_at)
    expect(StaffRolePolicy.allowed?(accountant, :manage_client_configuration, company: company)).to be(false)
  end

  it "preserves grants through bulk membership and profile updates, ignoring injected grant attributes" do
    grant!
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(admin)
    put "/api/v1/admin/company_assignments/bulk_update", params: { user_id: accountant.id, company_ids: [ company.id, other_company.id ], client_management: false }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.client_management).to be(true)
    expect(other_assignment.reload.client_management).to be(false)
    patch "/api/v1/admin/users/#{accountant.id}", params: { user: { name: "Saved Profile", company_ids: [ company.id, other_company.id ], client_management: false } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(assignment.reload.client_management).to be(true)
    expect(other_assignment.reload.client_management).to be(false)
  end
end
