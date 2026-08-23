# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollAccess::RevocationDispatcher do
  let(:user) { create(:user, active: false) }

  before do
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user)
    allow(Rails.logger).to receive(:error)
  end

  it "persists a retryable revocation job" do
    job = instance_double(RevokePayrollAccessJob)
    allow(RevokePayrollAccessJob).to receive(:perform_later).with(user.id).and_return(job)

    expect(described_class.call(user)).to eq(job)
    expect(PayrollAccess::SessionRevoker).not_to have_received(:disconnect_user)
  end

  it "falls back to an immediate disconnect when enqueue raises" do
    allow(RevokePayrollAccessJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")

    described_class.call(user)

    expect(PayrollAccess::SessionRevoker).to have_received(:disconnect_user).with(user)
  end

  it "falls back when an enqueue callback halts the job" do
    allow(RevokePayrollAccessJob).to receive(:perform_later).and_return(false)

    described_class.call(user)

    expect(PayrollAccess::SessionRevoker).to have_received(:disconnect_user).with(user)
  end

  it "contains fallback failures so organization-wide revocation can continue" do
    allow(RevokePayrollAccessJob).to receive(:perform_later).and_raise(StandardError, "queue unavailable")
    allow(PayrollAccess::SessionRevoker).to receive(:disconnect_user).and_raise(StandardError, "adapter unavailable")

    expect(described_class.call(user)).to eq(false)
    expect(Rails.logger).to have_received(:error).with(include("Immediate disconnect failed", "user=#{user.id}"))
  end
end
