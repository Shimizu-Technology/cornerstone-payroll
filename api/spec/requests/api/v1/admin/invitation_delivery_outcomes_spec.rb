# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin invitation delivery outcomes", type: :request do
  let!(:actor) { create(:user, role: "super_admin", email: "actor@example.test", clerk_id: "user_actor") }
  let!(:invitee) do
    create(:user, company: actor.company, organization: actor.organization,
      email: "invitee@example.test", clerk_id: "user_invitee", invitation_status: "pending")
  end

  around do |example|
    original = ENV.to_h
    ENV.delete("DEPLOYMENT_ENV")
    ENV.delete("STAGING_MAIL_ALLOWLIST")
    ENV.delete("RESEND_API_KEY")
    ENV["RESEND_FROM_EMAIL"] = "sender@example.test"
    ENV["FRONTEND_URL"] = "https://payroll-web-staging.example.test"
    example.run
  ensure
    ENV.replace(original)
  end

  before do
    [ Api::V1::Admin::UsersController, Api::V1::Admin::OrganizationsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)
    end
    allow_any_instance_of(ClerkInvitationService).to receive(:configured?).and_return(true)
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation)
      .and_return(success: true, invitation_id: "inv_synthetic", url: "https://synthetic.clerk.accounts.dev/invite")
    expect(Resend::Emails).not_to receive(:send)
  end

  def request_invitation(path)
    case path
    when :create_user
      post "/api/v1/admin/users", params: { user: { email: "new@example.test", name: "New User", role: "employee" } }
    when :resend
      post "/api/v1/admin/users/#{invitee.id}/resend_invitation"
    when :create_organization
      post "/api/v1/admin/organizations", params: { organization: { name: "Synthetic New Firm", admin: { email: "new@example.test" } } }
    when :create_admin
      actor.organization.update!(primary_company: actor.company)
      post "/api/v1/admin/organizations/#{actor.organization_id}/admin_users", params: { user: { email: "new@example.test" } }
    end
    expect(response).to have_http_status(path == :resend ? :ok : :created)
  end

  %i[create_user resend create_organization create_admin].each do |path|
    it "reports an ordinary #{path} enqueue as queued, never provider-submitted" do
      expect(SendUserInviteEmailJob).to receive(:perform_later).and_return(double("enqueued job"))
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "queued", "invitation_sent" => false, "invitation_error" => nil)
    end

    it "reports actual staging capture for #{path}, without queueing or contacting Resend" do
      ENV["DEPLOYMENT_ENV"] = "staging"
      ENV["STAGING_TESTER_BINDINGS"] = [ actor, invitee ].map { |user| { user_id: user.id, email: user.email, clerk_subject: user.clerk_id } }.to_json
      expect(SendUserInviteEmailJob).not_to receive(:perform_later)
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "captured", "invitation_sent" => false, "invitation_error" => nil)
    end

    it "reports a synchronous staging provider submission for #{path}" do
      allow(StagingOutboundPolicy).to receive(:staging?).and_return(true)
      allow(UserInviteEmailService).to receive(:send_invite).and_return(true)
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "submitted", "invitation_sent" => true)
    end

    it "retains the saved account and reports an enqueue failure for #{path}" do
      allow(SendUserInviteEmailJob).to receive(:perform_later).and_return(false)
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false)
      expect(response.parsed_body.fetch("invitation_error")).to be_present
      expect(User.exists?(response.parsed_body.fetch(path == :create_organization ? "admin_user" : "data").fetch("id"))).to be(true)
    end

    it "reports synchronous staging transport failure for #{path}" do
      allow(StagingOutboundPolicy).to receive(:staging?).and_return(true)
      allow(UserInviteEmailService).to receive(:send_invite).and_return(false)
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false)
      expect(response.parsed_body.fetch("invitation_error")).to be_present
    end
  end

  it "reports not_requested when creating an organization without an admin" do
    expect(SendUserInviteEmailJob).not_to receive(:perform_later)
    post "/api/v1/admin/organizations", params: { organization: { name: "No Admin Firm" } }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("invitation_delivery_status" => "not_requested", "invitation_sent" => false, "invitation_error" => nil)
  end

  it "reports Clerk failure without queueing an email" do
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_return(success: false, error: "Synthetic invitation failure")
    expect(SendUserInviteEmailJob).not_to receive(:perform_later)
    request_invitation(:resend)
    expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false, "invitation_error" => "Synthetic invitation failure")
  end

  it "reports a missing invitation URL as failure rather than a silent success" do
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_return(success: true, invitation_id: "inv_synthetic")
    expect(SendUserInviteEmailJob).not_to receive(:perform_later)
    request_invitation(:resend)
    expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false)
    expect(response.parsed_body.fetch("invitation_error")).to be_present
  end

  it "returns an enqueue exception as a failed outcome without exposing exception content" do
    allow(SendUserInviteEmailJob).to receive(:perform_later).and_raise(RuntimeError, "PRIVATE_EXCEPTION")
    request_invitation(:resend)
    expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false)
    expect(response.body).not_to include("PRIVATE_EXCEPTION")
  end
end
