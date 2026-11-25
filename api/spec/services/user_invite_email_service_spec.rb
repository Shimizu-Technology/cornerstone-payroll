# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserInviteEmailService do
  let(:user) { create(:user, role: "client", email: "owner+invite@client.example") }
  let(:logged) { [] }

  around do |example|
    saved = ENV.to_h.slice("RESEND_API_KEY", "RESEND_FROM_EMAIL")
    ENV.update("RESEND_API_KEY" => "re_test_synthetic", "RESEND_FROM_EMAIL" => "payroll@mail.example")
    example.run
  ensure
    %w[RESEND_API_KEY RESEND_FROM_EMAIL].each { |key| ENV[key] = saved[key] }
  end

  before do
    allow(StagingOutboundPolicy).to receive(:staging?).and_return(false)
    allow(Rails.logger).to receive(:info) { |line| logged << line }
    allow(Rails.logger).to receive(:error) { |line| logged << line }
  end

  it "logs the recipient's domain only, whether the email sends or fails" do
    allow(StagingMailTransport).to receive(:deliver).and_return({ "id" => "em_1" })
    expect(described_class.send_invite(user: user, invited_by: nil)).to be(true)

    allow(StagingMailTransport).to receive(:deliver).and_raise(StandardError, "rejected #{user.email}")
    expect(described_class.send_invite(user: user, invited_by: nil)).to be(false)

    expect(logged.join).to include("***@client.example")
    expect(logged.join).not_to include("owner+invite")
  end
end
