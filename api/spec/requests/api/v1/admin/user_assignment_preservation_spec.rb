# frozen_string_literal: true

require "rails_helper"

RSpec.describe "User profile assignment preservation", type: :request do
  let!(:organization) { create(:organization) }
  let!(:home) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: home, role: "admin") }
  let!(:original_grantor) { create(:user, company: home, role: "admin") }
  let!(:staff) { create(:user, company: home, role: "manager", name: "QA Reviewer") }
  let!(:live_assignment) { create(:company_assignment, user: staff, company: home, granted_by: original_grantor) }
  let!(:workspace) do
    create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: home,
      migration_rehearsal_status: "ready", test_workspace_expires_at: 30.days.from_now)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user_id).and_return(actor.id)
  end

  def profile_company_ids
    get "/api/v1/admin/users/#{staff.id}"
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("data").fetch("assigned_company_ids", [])
  end

  %w[reviewer workspace_admin].each do |level|
    [ false, true ].each do |expired|
      it "preserves an #{expired ? 'expired' : 'active'} #{level} grant verbatim when saving the UI's unchanged selection" do
        grant = create(:company_assignment, user: staff, company: workspace,
          workspace_access_level: level, expires_at: expired ? 1.day.ago : 5.days.from_now,
          granted_by: original_grantor)
        original_grant = grant.reload.attributes
        original_live = live_assignment.reload.attributes
        selected_ids = profile_company_ids
        expect(selected_ids.include?(workspace.id)).to be(!expired)

        patch "/api/v1/admin/users/#{staff.id}", params: {
          user: { name: "Renamed QA Reviewer", role: "manager", company_ids: selected_ids }
        }

        expect(response).to have_http_status(:ok)
        expect(staff.reload.name).to eq("Renamed QA Reviewer")
        expect(grant.reload.attributes).to eq(original_grant)
        expect(live_assignment.reload.attributes).to eq(original_live)
        expect(TestWorkspaceAccessPolicy.allowed?(user: staff, company: workspace,
          request_method: "PATCH", capability: :manage_client_configuration)).to be(!expired && level == "workspace_admin")
      end
    end
  end

  it "does not renew a retained grant that expired after the edit form was opened" do
    grant = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: original_grantor)
    selected_ids = profile_company_ids
    expect(selected_ids).to include(workspace.id)
    grant.update!(expires_at: 1.minute.ago)
    expired_grant = grant.reload.attributes

    patch "/api/v1/admin/users/#{staff.id}", params: {
      user: { name: "Saved after expiry", role: "manager", company_ids: selected_ids }
    }

    expect(response).to have_http_status(:ok)
    expect(grant.reload.attributes).to eq(expired_grant)
    expect(response.parsed_body.fetch("data").fetch("assigned_company_ids")).not_to include(workspace.id)
    expect(TestWorkspaceAccessPolicy.allowed?(user: staff, company: workspace,
      request_method: "POST", capability: :payroll_operations)).to be(false)
  end

  it "removes only an unselected active membership and creates only a newly selected workspace grant" do
    retained = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: original_grantor)
    original_retained = retained.reload.attributes
    added_workspace = create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: home, migration_rehearsal_status: "ready")

    patch "/api/v1/admin/users/#{staff.id}", params: {
      user: { name: staff.name, role: "manager", company_ids: [ workspace.id, added_workspace.id ] }
    }

    expect(response).to have_http_status(:ok)
    expect(retained.reload.attributes).to eq(original_retained)
    expect(CompanyAssignment.exists?(live_assignment.id)).to be(false)
    expect(staff.company_assignments.reload.pluck(:company_id)).to match_array([ workspace.id, added_workspace.id ])
    expect(staff.company_assignments.find_by!(company_id: added_workspace.id)).to have_attributes(
      workspace_access_level: "operator", expires_at: nil, granted_by_id: actor.id)
  end

  it "rejects a retained workspace assignment when the requested role is a client portal user" do
    grant = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: original_grantor)
    original_grant = grant.reload.attributes
    original_staff = staff.reload.attributes

    patch "/api/v1/admin/users/#{staff.id}", params: {
      user: { name: "Invalid client transition", role: "client", company_ids: [ home.id, workspace.id ] }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(staff.reload.attributes).to eq(original_staff)
    expect(grant.reload.attributes).to eq(original_grant)
  end

  it "removes an omitted expired staff-only grant during an intentional client role transition" do
    grant = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 1.day.ago, granted_by: original_grantor)
    original_live = live_assignment.reload.attributes

    patch "/api/v1/admin/users/#{staff.id}", params: {
      user: { name: staff.name, role: "client", company_ids: [ home.id ] }
    }

    expect(response).to have_http_status(:ok)
    expect(staff.reload.role).to eq("client")
    expect(CompanyAssignment.exists?(grant.id)).to be(false)
    expect(live_assignment.reload.attributes).to eq(original_live)
  end

  it "rolls back profile and membership changes if a new foreign assignment fails validation" do
    actor.update!(role: "super_admin")
    grant = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: original_grantor)
    foreign_company = create(:company)
    original_staff = staff.reload.attributes
    original_grants = staff.company_assignments.reload.order(:id).map(&:attributes)

    expect {
      patch "/api/v1/admin/users/#{staff.id}", params: {
        user: { name: "Must roll back", role: "accountant", company_ids: [ workspace.id, foreign_company.id ] }
      }
    }.not_to change { AuditLog.where(action: "users#updated", record_id: staff.id).count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Company must belong to the user's organization")
    expect(staff.reload.attributes).to eq(original_staff)
    expect(staff.company_assignments.reload.order(:id).map(&:attributes)).to eq(original_grants)
    expect(grant.reload.workspace_access_level).to eq("reviewer")
  end
end
