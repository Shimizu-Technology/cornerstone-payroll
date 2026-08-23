# frozen_string_literal: true

require "rails_helper"

RSpec.describe RevokePayrollAccessJob, type: :job do
  it "disconnects a user whose local payroll access has been revoked" do
    user = create(:user, active: false)
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)

    described_class.perform_now(user.id)

    expect(PayrollAccess::SessionRevoker).to have_received(:disconnect_user).with(user)
  end

  it "does not disconnect a user whose access was restored before the job ran" do
    user = create(:user, active: true)
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)

    described_class.perform_now(user.id)

    expect(PayrollAccess::SessionRevoker).not_to have_received(:disconnect_user)
  end

  it "does nothing when the user was deleted before the job ran" do
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)

    described_class.perform_now(-1)

    expect(PayrollAccess::SessionRevoker).not_to have_received(:disconnect_user)
  end

  it "re-enqueues adapter failures through the Active Job retry policy" do
    user = create(:user, active: false)
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user).and_raise(StandardError, "adapter unavailable")

    expect { described_class.perform_now(user.id) }
      .to have_enqueued_job(described_class).with(user.id)
  end
end
