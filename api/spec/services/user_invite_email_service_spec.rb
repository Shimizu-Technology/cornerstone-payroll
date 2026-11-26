# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

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

  # Clerk's invitation URL: accepting it forwards to the app's /login with
  # __clerk_ticket, which the embedded Clerk widget needs on an invite-only
  # instance.
  let(:invitation_url) { "https://clerk.payroll.example.test/v1/tickets/accept?ticket=tk_synthetic_123" }

  it "links to the Clerk invitation, ticket included, and sends nothing without one" do
    sent = []
    allow(StagingMailTransport).to receive(:deliver) { |payload| sent << payload && { "id" => "em_1" } }

    expect(described_class.send_invite(user: user, invited_by: nil, invitation_url: invitation_url)).to be(true)
    html = sent.sole.fetch(:html)
    expect(html).to include(%(href="#{CGI.escapeHTML(invitation_url)}"))
    expect(html).to include("ticket=tk_synthetic_123")
    expect(html).not_to match(%r{href="[^"]*/login"})
    expect(html).to include("opens account setup directly")
    expect(html).not_to include("Choose")
    expect(html).not_to include("Sign up")

    [ nil, "", "/login", "javascript:alert(1)" ].each do |url|
      expect(described_class.send_invite(user: user, invited_by: nil, invitation_url: url)).to be(false)
    end
    expect(sent.size).to eq(1)
  end

  it "logs the recipient's domain only, whether the email sends or fails" do
    allow(StagingMailTransport).to receive(:deliver).and_return({ "id" => "em_1" })
    expect(described_class.send_invite(user: user, invited_by: nil, invitation_url: invitation_url)).to be(true)

    allow(StagingMailTransport).to receive(:deliver).and_raise(StandardError, "rejected #{user.email}")
    expect(described_class.send_invite(user: user, invited_by: nil, invitation_url: invitation_url)).to be(false)

    expect(logged.join).to include("***@client.example")
    expect(logged.join).not_to include("owner+invite")
  end

  it "logs the Resend message id returned by Resend::Emails.send" do
    saved_key = Resend.api_key
    Resend.api_key = "re_test_synthetic"
    stub_request(:post, "https://api.resend.com/emails")
      .to_return(status: 200, body: { id: "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794" }.to_json,
        headers: { "Content-Type" => "application/json" })

    expect(described_class.send_invite(user: user, invited_by: nil, invitation_url: invitation_url)).to be(true)
    expect(logged.join).to include("id=49a3999c-0ce1-4ea6-ab68-afcd6dc2e794")
  ensure
    Resend.api_key = saved_key
  end
end
