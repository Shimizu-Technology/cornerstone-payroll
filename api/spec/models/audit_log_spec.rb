require "rails_helper"

RSpec.describe AuditLog, type: :model do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:user) { create(:user, organization: organization, company: company, role: :admin) }

  it "snapshots actor and request context when it is recorded" do
    Current.user = user
    Current.organization_id = organization.id
    Current.request_id = "request-123"
    Current.ip_address = "127.0.0.1"

    log = described_class.record!(action: "users#updated", record_type: "users", record_id: user.id)

    expect(log).to have_attributes(
      actor_name: user.name,
      actor_email: user.email,
      actor_role: "admin",
      organization_id: organization.id,
      request_id: "request-123",
      ip_address: "127.0.0.1"
    )
  ensure
    Current.reset
  end

  it "does not allow persisted history to be edited" do
    log = described_class.record!(user: user, action: "test#create", record_type: "test")

    expect { log.update!(action: "rewritten") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
