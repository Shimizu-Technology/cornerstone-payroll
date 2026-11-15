require "rails_helper"

RSpec.describe "Moving a practice-only login between practice copies", type: :request do
  let(:organization) { create(:organization) }
  let(:source) { create(:company, organization: organization, name: "Synthetic Bakery") }
  let(:admin) { create(:user, company: source, role: "org_admin") }
  let(:old_copy) { practice_copy("Synthetic Bakery practice A") }
  let(:new_copy) { practice_copy("Synthetic Bakery practice B") }
  let(:login) do
    user = create(:user, company: old_copy, practice_company: old_copy, role: "client", email: "practice-login@example.invalid",
      name: "Practice Login")
    CompanyAssignment.create!(user: user, company: old_copy, granted_by: admin)
    user
  end
  let(:acting_user) { admin }

  def practice_copy(name, **attrs)
    create(:company, organization: organization, name: name, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: source, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 90.days.from_now, **attrs)
  end

  def archive_old_copy!
    login
    TestWorkspace::Lifecycle.new(company: old_copy, actor: admin).archive!
    login.reload
  end

  def move!(company_id: new_copy.id, activate: true)
    post "/api/v1/admin/users/#{login.id}/move_practice_copy", params: { company_id: company_id, activate: activate }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user) { acting_user }
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:create_clerk_invitation).and_return(success: false, error: "Test: outbound blocked")
  end

  it "moves an archived copy's login to a ready copy, activates it and keeps its old history attributed" do
    document = create(:client_document, company: old_copy, uploaded_by: login)
    archive_old_copy!
    expect(login).not_to be_active
    login.update_columns(invitation_status: "accepted")

    expect { move! }.to change { AuditLog.where(action: "users#practice_copy_moved").count }.by(1)

    expect(response).to have_http_status(:ok), response.body
    body = response.parsed_body
    expect(body.dig("data", "practice_company_id")).to eq(new_copy.id)
    expect(body.dig("data", "practice_copy_closed_reason")).to be_nil
    expect(body.dig("data", "active")).to be(true)
    expect(body.dig("moved_from", "id")).to eq(old_copy.id)

    login.reload
    expect(login).to have_attributes(company_id: new_copy.id, practice_company_id: new_copy.id, active: true)
    expect(login.company_assignments.pluck(:company_id)).to eq([ new_copy.id ])
    expect(login.accessible_company_ids).to eq([ new_copy.id ])
    expect(login.can_access_company?(old_copy.id)).to be(false)
    expect(login.can_access_company?(source.id)).to be(false)
    expect(document.reload.uploaded_by_id).to eq(login.id)
    expect(document.company_id).to eq(old_copy.id)

    audit = AuditLog.find_by!(action: "users#practice_copy_moved")
    expect(audit).to have_attributes(user_id: admin.id, record_id: login.id, company_id: new_copy.id)
    expect(audit.metadata).to include("from_company_id" => old_copy.id, "to_company_id" => new_copy.id, "activated" => true)
  end

  it "can move without activating, leaving the login inactive" do
    archive_old_copy!
    move!(activate: false)

    expect(response).to have_http_status(:ok), response.body
    expect(login.reload).to have_attributes(practice_company_id: new_copy.id, active: false)
    expect(login.company_assignments.pluck(:company_id)).to eq([ new_copy.id ])
  end

  it "replaces a pending invitation when the moved login is activated" do
    archive_old_copy!
    login.update_columns(invitation_status: "pending", clerk_invitation_id: "inv_old")
    clerk = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(clerk)
    expect(clerk).to receive(:revoke_invitation).with("inv_old").and_return(success: true)

    move!

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body["invitation_delivery_status"]).to eq("failed")
    expect(login.reload.practice_company_id).to eq(new_copy.id)
  end

  it "denies a user who is not an organization administrator" do
    archive_old_copy!
    accountant = create(:user, company: source, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(accountant)

    move!

    expect(response).to have_http_status(:forbidden)
    expect(login.reload.practice_company_id).to eq(old_copy.id)
  end

  it "denies an administrator from another organization" do
    archive_old_copy!
    other_admin = create(:user, company: create(:company), role: "org_admin")
    allow_any_instance_of(Api::V1::Admin::UsersController).to receive(:current_user).and_return(other_admin)

    move!

    expect(response).to have_http_status(:not_found)
    expect(login.reload.practice_company_id).to eq(old_copy.id)
  end

  it "denies a target copy in another organization" do
    archive_old_copy!
    foreign_source = create(:company)
    foreign_copy = create(:company, organization: foreign_source.organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: foreign_source, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 90.days.from_now)

    move!(company_id: foreign_copy.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("target_unavailable")
    expect(login.reload.practice_company_id).to eq(old_copy.id)
  end

  it "denies a real client as the target" do
    archive_old_copy!

    move!(company_id: source.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("code" => "target_not_practice_copy",
      "error" => "A practice login can use a practice copy only, never a real client")
    expect(login.reload).to have_attributes(practice_company_id: old_copy.id, company_id: old_copy.id)
    expect(login.company_assignments.pluck(:company_id)).to eq([ old_copy.id ])
  end

  {
    "archived" => { test_workspace_archived_at: 1.day.ago, active: false },
    "expired" => { test_workspace_expires_at: 1.day.ago },
    "sealed (read-only)" => { test_workspace_sealed_at: 1.day.ago },
    "still being prepared" => { migration_rehearsal_status: "pending" }
  }.each do |label, attrs|
    it "denies a target copy that is #{label}" do
      archive_old_copy!
      target = practice_copy("Closed target", **attrs)

      move!(company_id: target.id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("target_unavailable")
      expect(login.reload.practice_company_id).to eq(old_copy.id)
    end
  end

  it "denies a backup snapshot as the target" do
    archive_old_copy!
    backup = practice_copy("Backup", test_workspace_purpose: "backup_snapshot", test_workspace_sealed_at: 1.day.ago)

    move!(company_id: backup.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("target_not_practice_copy")
    expect(login.reload.practice_company_id).to eq(old_copy.id)
  end

  it "denies a copy of a different real client, since each copy holds that client's payroll data" do
    archive_old_copy!
    other_source = create(:company, organization: organization, name: "Synthetic Garage")
    other_copy = practice_copy("Synthetic Garage practice", migration_source_company: other_source)

    expect { move!(company_id: other_copy.id) }.not_to change(AuditLog, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("target_other_client")
    expect(response.parsed_body["error"]).to include("another copy of Synthetic Bakery")
    expect(login.reload).to have_attributes(practice_company_id: old_copy.id, company_id: old_copy.id, active: false)
    expect(login.company_assignments.pluck(:company_id)).to eq([ old_copy.id ])
  end

  it "revokes a pending invitation when the login is moved without activating" do
    archive_old_copy!
    login.update_columns(invitation_status: "pending", clerk_invitation_id: "inv_old")
    clerk = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(clerk)
    expect(clerk).to receive(:revoke_invitation).with("inv_old").and_return(success: true)

    move!(activate: false)

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).not_to have_key("invitation_delivery_status")
    expect(login.reload).to have_attributes(practice_company_id: new_copy.id, active: false, clerk_invitation_id: nil)
  end

  it "rolls the whole move back when a step fails, and leaves ordinary updates blocked" do
    archive_old_copy!
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "synthetic failure")
    service = TestWorkspace::MovePracticeLogin.new(user: login, target_company: new_copy, actor: admin, activate: true)

    expect { service.call }.to raise_error(ActiveRecord::StatementInvalid)

    expect(login.reload).to have_attributes(practice_company_id: old_copy.id, company_id: old_copy.id, active: false)
    expect(login.company_assignments.pluck(:company_id)).to eq([ old_copy.id ])
    login.practice_company = new_copy
    login.company = new_copy
    expect(login).not_to be_valid
    expect(login.errors[:practice_company]).to include("cannot be changed for a practice-only login")
  end

  it "denies the move while the login's current copy is still open" do
    login

    move!

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("source_copy_open")
    expect(login.reload).to have_attributes(practice_company_id: old_copy.id, active: true)
  end

  it "refuses to move an ordinary client login" do
    real_login = create(:user, company: source, role: "client")

    post "/api/v1/admin/users/#{real_login.id}/move_practice_copy", params: { company_id: new_copy.id }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["code"]).to eq("not_practice_login")
    expect(real_login.reload.practice_company_id).to be_nil
  end

  it "still refuses to re-point a practice login through ordinary updates" do
    archive_old_copy!
    login.practice_company = new_copy
    login.company = new_copy
    expect(login).not_to be_valid
    expect(login.errors[:practice_company]).to include("cannot be changed for a practice-only login")
  end

  describe "actionable errors" do
    it "explains an Activate on an archived copy and points to Move" do
      archive_old_copy!

      post "/api/v1/admin/users/#{login.id}/activate"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["code"]).to eq("practice_copy_closed")
      expect(response.parsed_body["error"]).to eq(
        "Practice Login belongs to practice copy Synthetic Bakery practice A, which is archived. " \
        "To use this login again, choose Move and pick a current practice copy."
      )
      expect(response.parsed_body["error"]).not_to include("must be a ready")
      expect(login.reload).not_to be_active
    end

    it "renews a lapsed grant when Activate is used on a login whose copy is still open" do
      login.update_columns(active: false)
      login.company_assignments.update_all(expires_at: 1.day.ago)

      expect { post "/api/v1/admin/users/#{login.id}/activate" }
        .to change { AuditLog.where(action: "test_workspace#portal_access_granted").count }.by(1)

      expect(response).to have_http_status(:ok), response.body
      expect(login.reload).to be_active
      expect(login.company_assignments.active_access.pluck(:company_id)).to eq([ old_copy.id ])
      expect(login.company_assignments.sole.expires_at).to be_within(1.second).of(old_copy.test_workspace_expires_at)
    end

    it "explains a refused Delete of a practice login with retained history" do
      archive_old_copy!
      create(:client_document, company: old_copy, uploaded_by: admin, reviewed_by: login, reviewed_at: Time.current)

      expect { delete "/api/v1/admin/users/#{login.id}" }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("code" => "user_has_retained_history", "practice_login" => true)
      expect(response.parsed_body["error"]).to include("can't be deleted because their name is on")
      expect(response.parsed_body["error"]).to include("choose Move to use the login with a current practice copy")
    end

    it "lists the practice copy state for the Users page" do
      archive_old_copy!

      get "/api/v1/admin/users"

      row = response.parsed_body.fetch("data").find { |user| user["id"] == login.id }
      expect(row).to include("practice_company_id" => old_copy.id, "practice_company_name" => old_copy.name,
        "practice_copy_closed_reason" => "archived", "practice_company_source_id" => source.id)
    end
  end
end
