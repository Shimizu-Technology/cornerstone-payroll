# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin invitation delivery outcomes", type: :request do
  let!(:actor) { create(:user, role: "super_admin", email: "actor@example.test", clerk_id: "user_actor") }
  let!(:invitee) do
    create(:user, company: actor.company, organization: actor.organization,
      email: "invitee@example.test", clerk_id: "pending_invitee", invitation_status: "pending")
  end

  around do |example|
    original = ENV.to_h
    ENV.delete("DEPLOYMENT_ENV")
    ENV.delete("STAGING_MAIL_ALLOWLIST")
    # Configured, as in production; Resend itself is never called (below).
    ENV["RESEND_API_KEY"] = "re_test_synthetic"
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
      post "/api/v1/admin/users", params: { user: { email: "new@example.test", name: "New User", role: "accountant" } }
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
    # Production Clerk is invite-only, and the first sign-in binds through the
    # accepted invitation: the email must carry Clerk's invitation URL.
    it "emails the Clerk invitation URL for #{path}, not a bare login link" do
      queued = []
      allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
      request_invitation(path)
      sent = []
      allow(StagingMailTransport).to receive(:deliver) { |payload| sent << payload && { "id" => "synthetic" } }
      SendUserInviteEmailJob.perform_now(*queued.sole)
      expect(sent.sole.fetch(:html)).to include(%(href="https://synthetic.clerk.accounts.dev/invite"))
      expect(sent.sole.fetch(:html)).not_to include(%(href="https://payroll-web-staging.example.test/login"))
    end

    it "reports an ordinary #{path} enqueue as queued, never provider-submitted" do
      expect(SendUserInviteEmailJob).to receive(:perform_later).and_return(double("enqueued job"))
      request_invitation(path)
      expect(response.parsed_body).to include("invitation_delivery_status" => "queued", "invitation_sent" => false, "invitation_error" => nil)
    end

    it "reports #{path} as skipped, not queued, when email delivery isn't configured" do
      ENV.delete("RESEND_API_KEY")
      logged = []
      allow(Rails.logger).to receive(:error) { |line| logged << line }
      expect(SendUserInviteEmailJob).not_to receive(:perform_later)
      request_invitation(path)

      body = response.parsed_body
      expect(body).to include("invitation_delivery_status" => "skipped", "invitation_sent" => false)
      expect(body.fetch("invitation_error")).to include("no invitation email was sent")
      user = User.find(body.fetch(path == :create_organization ? "admin_user" : "data").fetch("id"))
      expect(user.invite_email_status).to eq("skipped")
      expect(user.invite_email_status_at).to be_present
      expect(logged.join).to include("Skipped user_id=#{user.id}")
      expect(logged.join).not_to include(user.email)
    end

    it "reports actual staging capture for #{path}, without queueing or contacting Resend" do
      ENV["DEPLOYMENT_ENV"] = "staging"
      ENV["STAGING_TESTER_BINDINGS"] = [ actor, invitee ].map { |user| { user_id: user.id, email: user.email, clerk_subject: user == invitee ? "user_invitee" : user.clerk_id } }.to_json
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

  it "records a queued invite email, then what the job did with it, and lists it for staff" do
    queued = []
    allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
    request_invitation(:resend)
    expect(invitee.reload.invite_email_status).to eq("queued")

    allow(StagingMailTransport).to receive(:deliver).and_raise(StandardError, "synthetic provider outage")
    # retry_on schedules another attempt rather than raising here.
    SendUserInviteEmailJob.perform_now(*queued.sole)
    expect(invitee.reload.invite_email_status).to eq("failed")

    get "/api/v1/admin/users"
    row = response.parsed_body.fetch("data").find { |user| user.fetch("id") == invitee.id }
    expect(row).to include("invitation_pending" => true, "invite_email_status" => "failed")
    expect(row.fetch("invite_email_status_at")).to be_present

    allow(StagingMailTransport).to receive(:deliver).and_return({ "id" => "synthetic" })
    SendUserInviteEmailJob.perform_now(*queued.sole)
    expect(invitee.reload.invite_email_status).to eq("sent")
  end

  it "pins the job to its invitation: a stale retry after a resend neither sends nor overwrites the newer status" do
    queued = []
    allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
    request_invitation(:resend)
    first = queued.last
    expect(first.last).to eq("inv_synthetic")
    expect(invitee.reload.clerk_invitation_id).to eq("inv_synthetic")

    # A resend replaces the invitation (the old link is revoked) and its email goes out.
    allow_any_instance_of(ClerkInvitationService).to receive(:invitation_status).and_return("pending")
    allow_any_instance_of(ClerkInvitationService).to receive(:revoke_invitation).and_return(success: true)
    allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation)
      .and_return(success: true, invitation_id: "inv_newer", url: "https://synthetic.clerk.accounts.dev/invite-newer")
    request_invitation(:resend)
    sent = []
    allow(StagingMailTransport).to receive(:deliver) { |payload| sent << payload && { "id" => "synthetic" } }
    SendUserInviteEmailJob.perform_now(*queued.last)
    expect(invitee.reload.invite_email_status).to eq("sent")

    expect(SendUserInviteEmailJob.perform_now(*first)).to eq(:stale)
    expect(sent.size).to eq(1)
    expect(sent.sole.fetch(:html)).to include("invite-newer")
    expect(invitee.reload.invite_email_status).to eq("sent")
  end

  it "sends nothing once the invite is accepted, including for a job queued before the invitation id was passed" do
    queued = []
    allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
    request_invitation(:resend)
    invitee.update_columns(invitation_status: "accepted")
    expect(StagingMailTransport).not_to receive(:deliver)

    expect(SendUserInviteEmailJob.perform_now(*queued.sole)).to eq(:stale)
    expect(SendUserInviteEmailJob.perform_now(*queued.sole.first(3))).to eq(:stale)
    expect(invitee.reload.invite_email_status).to eq("queued")
  end

  it "still sends a pending invite for a job queued before the invitation id was passed" do
    queued = []
    allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
    request_invitation(:resend)
    allow(StagingMailTransport).to receive(:deliver).and_return({ "id" => "synthetic" })

    SendUserInviteEmailJob.perform_now(*queued.sole.first(3))
    expect(StagingMailTransport).to have_received(:deliver).once
    expect(invitee.reload.invite_email_status).to eq("sent")
  end

  context "when Clerk doesn't issue a new invitation" do
    it "records failed for a Clerk error after any earlier invitation was closed" do
      allow_any_instance_of(ClerkInvitationService).to receive(:create_invitation).and_return(success: false, error: "Synthetic invitation failure")
      invitee.update_columns(invite_email_status: "sent")
      request_invitation(:resend)
      expect(invitee.reload.invite_email_status).to eq("failed")
    end

    it "records failed when Clerk isn't configured and no earlier invite email went out" do
      allow_any_instance_of(ClerkInvitationService).to receive(:configured?).and_return(false)
      request_invitation(:resend)
      expect(response.parsed_body).to include("invitation_delivery_status" => "failed")
      expect(invitee.reload.invite_email_status).to eq("failed")
    end

    it "keeps an earlier live invite's sent status when the failure left that invitation open" do
      allow_any_instance_of(ClerkInvitationService).to receive(:configured?).and_return(false)
      invitee.update_columns(invite_email_status: "sent")
      request_invitation(:resend)
      expect(invitee.reload.invite_email_status).to eq("sent")

      allow_any_instance_of(ClerkInvitationService).to receive(:configured?).and_return(true)
      invitee.update_columns(clerk_invitation_id: "inv_earlier")
      allow_any_instance_of(ClerkInvitationService).to receive(:invitation_status).with("inv_earlier").and_return("pending")
      allow_any_instance_of(ClerkInvitationService).to receive(:revoke_invitation).and_return(success: false, error_code: "synthetic")
      request_invitation(:resend)
      expect(response.parsed_body.fetch("invitation_error")).to include("previous invitation is closed")
      expect(invitee.reload.invite_email_status).to eq("sent")
    end

    it "leaves the status alone when Clerk says the earlier invitation was already accepted" do
      invitee.update_columns(clerk_invitation_id: "inv_earlier", invite_email_status: "sent")
      allow_any_instance_of(ClerkInvitationService).to receive(:invitation_status).with("inv_earlier").and_return("accepted")
      expect_any_instance_of(ClerkInvitationService).not_to receive(:create_invitation)
      request_invitation(:resend)
      expect(response.parsed_body.fetch("invitation_error")).to eq(PayrollInvitation::ACCEPTED_MESSAGE)
      expect(invitee.reload.invite_email_status).to eq("sent")
    end

    it "records refused when a demo login's address isn't allow-listed" do
      allow(DemoOutbound).to receive(:demo_company_for).and_return(actor.company)
      allow(DemoOutbound).to receive(:permit?).and_return(false)
      expect_any_instance_of(ClerkInvitationService).not_to receive(:create_invitation)
      request_invitation(:resend)
      expect(response.parsed_body).to include("invitation_delivery_status" => "failed")
      expect(invitee.reload.invite_email_status).to eq("refused")
    end
  end

  it "records a skip in the job, without retrying, when email stops being configured after the enqueue" do
    queued = []
    allow(SendUserInviteEmailJob).to receive(:perform_later) { |*args| queued << args }
    request_invitation(:resend)
    ENV.delete("RESEND_API_KEY")
    expect(StagingMailTransport).not_to receive(:deliver)

    expect(SendUserInviteEmailJob.perform_now(*queued.sole)).to eq(:skipped)
    expect(invitee.reload.invite_email_status).to eq("skipped")
  end

  it "records a failed enqueue on the login" do
    allow(SendUserInviteEmailJob).to receive(:perform_later).and_return(false)
    request_invitation(:resend)
    expect(invitee.reload.invite_email_status).to eq("failed")
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
    expect(invitee.reload.invite_email_status).to eq("failed")
  end

  it "returns an enqueue exception as a failed outcome without exposing exception content" do
    allow(SendUserInviteEmailJob).to receive(:perform_later).and_raise(RuntimeError, "PRIVATE_EXCEPTION")
    request_invitation(:resend)
    expect(response.parsed_body).to include("invitation_delivery_status" => "failed", "invitation_sent" => false)
    expect(response.body).not_to include("PRIVATE_EXCEPTION")
  end
end
