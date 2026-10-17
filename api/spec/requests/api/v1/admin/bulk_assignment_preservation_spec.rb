# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Bulk assignment metadata preservation", type: :request do
  let!(:organization) { create(:organization) }
  let!(:home) { create(:company, organization: organization) }
  let!(:actor) { create(:user, company: home, role: "admin") }
  let!(:grantor) { create(:user, company: home, role: "admin") }
  let!(:staff) { create(:user, company: home, role: "manager") }
  let!(:live_grant) { create(:company_assignment, user: staff, company: home, granted_by: grantor) }
  let!(:workspace) { create_workspace }

  before do
    allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::CompanyAssignmentsController).to receive(:current_user_id).and_return(actor.id)
  end

  def create_workspace
    create(:company, organization: organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: home,
      migration_rehearsal_status: "ready", test_workspace_expires_at: 30.days.from_now)
  end

  def saved_grants
    staff.company_assignments.reload.order(:id).map(&:attributes)
  end

  def replace_memberships(ids)
    put "/api/v1/admin/company_assignments/bulk_update", params: { user_id: staff.id, company_ids: ids }
  end

  %w[reviewer workspace_admin].each do |level|
    [ false, true ].each do |expired|
      it "preserves selected #{expired ? 'expired' : 'active'} #{level} metadata across repeated full-list saves" do
        grant = create(:company_assignment, user: staff, company: workspace,
          workspace_access_level: level, expires_at: expired ? 1.day.ago : 5.days.from_now, granted_by: grantor)
        original = saved_grants

        get "/api/v1/admin/company_assignments", params: { user_id: staff.id }
        expect(response).to have_http_status(:ok)
        rows = response.parsed_body.fetch("data")
        # Unlike the Users profile payload, this full-list endpoint includes expired grants.
        expect(rows.map { |row| row.fetch("id") }).to include(grant.id)
        ids = rows.map { |row| row.fetch("company_id") }

        2.times do
          replace_memberships(ids)

          expect(response).to have_http_status(:ok)
          expect(saved_grants).to eq(original)
          retained = response.parsed_body.fetch("data").find { |row| row.fetch("company_id") == workspace.id }
          expect(retained).to include("id" => grant.id, "workspace_access_level" => level,
            "granted_by_id" => grantor.id, "expires_at" => grant.reload.expires_at.as_json)
          expect(TestWorkspaceAccessPolicy.allowed?(user: staff, company: workspace,
            request_method: "PATCH", capability: :manage_client_configuration)).to be(!expired && level == "workspace_admin")
        end
      end
    end
  end

  it "retains only requested memberships and creates only a genuinely new default grant" do
    retained = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: grantor)
    omitted_workspace = create_workspace
    omitted_expired = create(:company_assignment, user: staff, company: omitted_workspace,
      workspace_access_level: "workspace_admin", expires_at: 1.day.ago, granted_by: grantor)
    added_workspace = create_workspace
    original_retained = retained.reload.attributes

    replace_memberships([ workspace.id, added_workspace.id ])

    expect(response).to have_http_status(:ok)
    expect(retained.reload.attributes).to eq(original_retained)
    expect(CompanyAssignment.exists?(live_grant.id)).to be(false)
    expect(CompanyAssignment.exists?(omitted_expired.id)).to be(false)
    expect(staff.company_assignments.reload.pluck(:company_id)).to match_array([ workspace.id, added_workspace.id ])
    expect(response.parsed_body.fetch("data").map { |row| row.fetch("company_id") }).to match_array([ workspace.id, added_workspace.id ])
    expect(staff.company_assignments.find_by!(company_id: added_workspace.id)).to have_attributes(
      workspace_access_level: "operator", expires_at: nil, granted_by_id: actor.id)
  end

  it "rejects an inaccessible selection before changing any retained or omitted grant" do
    create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: grantor)
    foreign_company = create(:company)
    original = saved_grants

    replace_memberships([ workspace.id, foreign_company.id ])

    expect(response).to have_http_status(:forbidden)
    expect(saved_grants).to eq(original)
  end

  it "validates retained workspace grants against the user's current role before any deletion" do
    create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "reviewer", expires_at: 5.days.from_now, granted_by: grantor)
    # Model-level role changes can leave a legacy incompatible grant. A bulk
    # membership save must validate that grant rather than silently retaining it.
    staff.update!(role: "client")
    original = saved_grants

    replace_memberships([ workspace.id ])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("test workspaces are available only to payroll staff")
    expect(saved_grants).to eq(original)
    expect(staff.reload.role).to eq("client")
  end

  it "rolls back removals and additions when a later foreign company fails model validation" do
    actor.update!(role: "super_admin")
    retained = create(:company_assignment, user: staff, company: workspace,
      workspace_access_level: "workspace_admin", expires_at: 5.days.from_now, granted_by: grantor)
    added_workspace = create_workspace
    foreign_company = create(:company)
    original = saved_grants

    replace_memberships([ workspace.id, added_workspace.id, foreign_company.id ])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Company must belong to the user's organization")
    expect(saved_grants).to eq(original)
    expect(retained.reload.workspace_access_level).to eq("workspace_admin")
    expect(staff.company_assignments.where(company_id: added_workspace.id)).not_to exist
  end
end
