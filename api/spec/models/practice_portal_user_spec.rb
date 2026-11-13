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
end
