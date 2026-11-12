# frozen_string_literal: true

require "rails_helper"

RSpec.describe PortalNotifications::RecipientListUpdate do
  let(:company) { create(:company, name: "Service Client") }
  let(:admin) { create(:user, company: company, role: "admin") }
  let(:staff) { create(:user, company: company, role: "manager", name: "Listed Manager") }

  it "replaces the list and returns the audited change set" do
    PortalNotificationRecipient.create!(company: company, email: "old@example.test")

    changes = described_class.call!(company: company, actor: admin, user_ids: [ staff.id, staff.id ], emails: [ "new@example.test" ])

    expect(changes).to eq(added_users: [ { id: staff.id, name: "Listed Manager" } ], removed_users: [],
      added_emails: [ "new@example.test" ], removed_emails: [ "old@example.test" ])
    expect(PortalNotificationRecipient.where(company: company).map { |row| row.user_id || row.email }).to contain_exactly(staff.id, "new@example.test")
    expect(PortalNotificationRecipient.find_by!(user: staff).added_by).to eq(admin)
    expect(AuditLog.find_by!(action: "portal_notification_recipients#update").metadata).to include("recipient_count" => 2)
  end

  it "raises before changing anything when a staff member cannot view the client" do
    PortalNotificationRecipient.create!(company: company, email: "kept@example.test")
    outsider = create(:user, role: "admin")

    expect do
      described_class.call!(company: company, actor: admin, user_ids: [ staff.id, outsider.id ], emails: [])
    end.to raise_error(described_class::IneligibleRecipient)
    expect(PortalNotificationRecipient.where(company: company).pluck(:email)).to eq([ "kept@example.test" ])
    expect(AuditLog.where(action: "portal_notification_recipients#update")).to be_empty
  end

  it "writes no audit record when nothing changed" do
    PortalNotificationRecipient.create!(company: company, user: staff)
    expect { described_class.call!(company: company, actor: admin, user_ids: [ staff.id ], emails: []) }.not_to change(AuditLog, :count)
  end
end
