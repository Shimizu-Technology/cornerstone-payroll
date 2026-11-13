require "rails_helper"

RSpec.describe "Practice portal identity" do
  let(:source) { create(:company) }
  let(:admin) { create(:user, company: source, role: "admin") }
  let(:workspace) do
    create(:company, organization: source.organization, payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox", migration_source_company: source, migration_rehearsal_status: "ready",
      test_workspace_expires_at: 1.day.from_now)
  end
  let(:client) do
    user = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: user, company: workspace, granted_by: admin)
    user
  end

  it "keeps the home, assignments and role permanently scoped to one practice copy" do
    expect(client.accessible_company_ids).to eq([ workspace.id ])
    expect(client.can_access_company?(source.id)).to be(false)
    expect(client.update(company: source)).to be(false)
    client.reload
    expect(client.update(practice_company: nil, company: source)).to be(false)
    client.reload
    expect(client.update(role: "admin")).to be(false)
    client.reload
    expect(build(:company_assignment, user: client, company: source)).not_to be_valid
    expect(build(:company_assignment, user: create(:user, company: source, role: "client"), company: workspace)).not_to be_valid
  end

  it "does not allow practice payroll to become a real invoice source" do
    invoice = build(:invoice, company: workspace, organization: source.organization)
    invoice.valid?
    expect(invoice.errors[:company]).to include("practice copies cannot be used for real invoices")
  end

  it "excludes practice copies from billing recipients and finance books" do
    recipient = build(:invoice_recipient, company: workspace, organization: source.organization)
    recipient.valid?
    expect(recipient.errors[:company]).to include("practice copies cannot be real billing recipients")
    book = FinanceBook.new(company: workspace, organization: source.organization, name: "Practice book", kind: "client")
    book.valid?
    expect(book.errors[:company]).to include("practice copies cannot have real financial books")
  end

  it "records a practice grant without staff privileges or an extended lifetime" do
    assignment = client.company_assignments.sole
    assignment.update!(workspace_access_level: "workspace_admin", expires_at: 1.year.from_now)
    expect(assignment.workspace_access_level).to be_nil
    expect(assignment.expires_at).to eq(workspace.test_workspace_expires_at)
    expect(AuditLog.where(action: "test_workspace#portal_access_granted", record_id: client.id)).to exist
  end

  it "deactivates and audits on archive and does not reactivate on restore" do
    client
    TestWorkspace::Lifecycle.new(company: workspace, actor: admin).archive!
    expect(client.reload).not_to be_active
    expect(client.accessible_company_ids).to be_empty
    expect(AuditLog.where(action: "test_workspace#portal_access_deactivated", record_id: client.id)).to exist
    TestWorkspace::Lifecycle.new(company: workspace, actor: admin).restore!
    expect(client.reload).not_to be_active
  end

  it "denies expired access immediately and persists deactivation without a login" do
    client
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    expect(client.accessible_company_ids).to be_empty
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload).not_to be_active
    expect(client.update(active: true)).to be(false)
  end

  it "does not restore access through the home company after its explicit grant is removed" do
    client.company_assignments.destroy_all
    expect(client.accessible_company_ids).to be_empty
    expect(client.payroll_access_allowed?).to be(false)
    expect(client.reload).not_to be_active
  end

  it "deactivates expired accounts at authentication before the scheduled sweep" do
    client
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    expect(client.payroll_access_allowed?).to be(false)
    expect(client.reload).not_to be_active
  end
  it "memoizes practice company ids until the user is reloaded" do
    expect(client).to receive(:practice_portal_open?).once.and_call_original
    2.times { expect(client.accessible_company_ids).to eq([ workspace.id ]) }
  end

  it "deactivates invalid profiles independently and revokes pending invitations on archive" do
    first = client
    second = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: second, company: workspace, granted_by: admin)
    first.update_columns(name: "", clerk_invitation_id: "inv_bad_profile", invitation_status: "pending")
    service = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(service)
    expect(service).to receive(:revoke_invitation).with("inv_bad_profile").and_return(success: true)
    expect(PayrollAccess::RevocationDispatcher).to receive(:call).with(have_attributes(id: first.id))
    expect(PayrollAccess::RevocationDispatcher).to receive(:call).with(have_attributes(id: second.id))
    TestWorkspace::Lifecycle.new(company: workspace, actor: admin).archive!
    expect(first.reload).not_to be_active
    expect(first.clerk_invitation_id).to be_nil
    expect(second.reload).not_to be_active
  end

  it "retries a failed invitation revocation on the next expiration sweep" do
    client.update_columns(clerk_invitation_id: "inv_expired", invitation_status: "pending")
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    service = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(service)
    expect(service).to receive(:revoke_invitation).with("inv_expired").and_raise(Timeout::Error)
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload).not_to be_active
    expect(client.clerk_invitation_id).to eq("inv_expired")
    expect(service).to receive(:revoke_invitation).with("inv_expired").and_return(success: true)
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload.clerk_invitation_id).to be_nil
  end
  it "retains the invitation if access reopens before the locked recheck" do
    client.update_columns(clerk_invitation_id: "inv_reopened", invitation_status: "pending")
    expect(client).to receive(:practice_portal_open?).ordered.and_return(false)
    expect(client).to receive(:practice_portal_open?).ordered.and_return(true)
    expect(ClerkInvitationService).not_to receive(:new)
    TestWorkspace::PortalAccess.deactivate_if_closed!(client)
    expect(client.reload).to be_active
    expect(client.clerk_invitation_id).to eq("inv_reopened")
  end

  it "does not clear an invitation replaced while Clerk revokes the old one" do
    client.update_columns(clerk_invitation_id: "inv_old", invitation_status: "pending")
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    service = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(service)
    expect(service).to receive(:revoke_invitation).with("inv_old") do
      workspace.update_columns(test_workspace_expires_at: 1.day.from_now)
      User.where(id: client.id).update_all(active: true, clerk_invitation_id: "inv_replacement")
      { success: true }
    end
    TestWorkspace::PortalAccess.deactivate_if_closed!(client)
    expect(client.reload).to be_active
    expect(client.clerk_invitation_id).to eq("inv_replacement")
  end

  it "stops retrying an invitation Clerk says is already closed, but keeps retrying rate limits" do
    client.update_columns(clerk_invitation_id: "inv_gone", invitation_status: "pending")
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    service = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(service)
    expect(service).to receive(:revoke_invitation).with("inv_gone").and_return(success: false, error: "rate limited", status: 429)
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload.clerk_invitation_id).to eq("inv_gone")
    expect(service).to receive(:revoke_invitation).with("inv_gone").and_return(success: false, error: "not found", status: 404)
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload.clerk_invitation_id).to be_nil
  end

  it "clears an invitation staging refuses to revoke instead of retrying every minute" do
    client.update_columns(clerk_invitation_id: "inv_staging", invitation_status: "pending")
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    service = instance_double(ClerkInvitationService, configured?: true)
    allow(ClerkInvitationService).to receive(:new).and_return(service)
    expect(service).to receive(:revoke_invitation).with("inv_staging").and_raise(StagingOutboundPolicy::Blocked)
    ExpirePracticePortalAccessJob.perform_now
    expect(client.reload.clerk_invitation_id).to be_nil
  end

  it "keeps sweeping other users when one user's deactivation fails" do
    other = create(:user, company: workspace, practice_company: workspace, role: "client")
    CompanyAssignment.create!(user: other, company: workspace, granted_by: admin)
    client
    workspace.update_columns(test_workspace_expires_at: 1.minute.ago)
    allow(TestWorkspace::PortalAccess).to receive(:deactivate_if_closed!).and_call_original
    allow(TestWorkspace::PortalAccess).to receive(:deactivate_if_closed!).with(having_attributes(id: [ client.id, other.id ].min)).and_raise(ActiveRecord::LockWaitTimeout)
    expect { ExpirePracticePortalAccessJob.perform_now }.not_to raise_error
    expect(User.find([ client.id, other.id ].max)).not_to be_active
  end
end
