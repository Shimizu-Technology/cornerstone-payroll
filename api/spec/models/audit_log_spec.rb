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
      actor_type: "staff_user",
      actor_id: user.id.to_s,
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

  it "prefers an explicit user over the explicit and current actors" do
    Current.set(actor: AuditActor.system_job("ExampleJob")) do
      log = described_class.record!(user: user, actor: AuditActor.operator("Operator"), action: "test#create", record_type: "test")

      expect(log).to have_attributes(user: user, actor_type: "staff_user", actor_id: user.id.to_s, actor_name: user.name)
    end
  end

  it "attributes a nil user to the current non-user actor" do
    Current.set(actor: AuditActor.kiosk(id: "door-1", name: "Lobby kiosk")) do
      log = described_class.record!(user: nil, action: "test#create", record_type: "test")

      expect(log).to have_attributes(user_id: nil, actor_type: "kiosk", actor_id: "door-1", actor_name: "Lobby kiosk")
    end
  end

  it "keeps an explicit non-user actor even when a user is authenticated" do
    employee = create(:employee)
    Current.set(user: user, actor: AuditActor.for_user(user)) do
      log = described_class.record!(actor: AuditActor.employee(employee), action: "test#create", record_type: "test")

      expect(log).to have_attributes(user_id: nil, actor_type: "employee", actor_id: employee.id.to_s, actor_name: employee.full_name)
    end
  end

  it "derives attribution for a direct insert using Current.actor" do
    Current.set(actor: AuditActor.operator("Release operator")) do
      log = described_class.create!(action: "test#create", record_type: "test")

      expect(log).to have_attributes(actor_type: "operator", actor_name: "Release operator", actor_role: "operator")
    end
  end

  it "rejects an unclassified write and an unsupported explicit type" do
    expect { described_class.record!(action: "test#create", record_type: "test") }
      .to raise_error(ActiveRecord::RecordInvalid) { |error| expect(error.record.errors[:actor_type]).to be_present }

    expect { described_class.create!(actor_type: "other", actor_name: "Operator", action: "test#create") }
      .to raise_error(ActiveRecord::RecordInvalid) { |error| expect(error.record.errors[:actor_type]).to be_present }
  end

  it "does not allow persisted history to be edited" do
    log = described_class.record!(user: user, action: "test#create", record_type: "test")

    expect { log.update!(action: "rewritten") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
