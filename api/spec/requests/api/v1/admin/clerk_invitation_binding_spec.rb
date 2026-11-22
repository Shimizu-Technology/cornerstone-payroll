# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll Clerk invitation administration", type: :request do
  let(:actor) { create(:user, role: :org_admin, clerk_id: "user_operator") }
  let(:invitee) do
    create(:user, company: actor.company, role: :client, invitation_status: "pending",
      clerk_id: "pending_invitee", clerk_invitation_id: "inv_original",
      invite_nonce_digest: Digest::SHA256.hexdigest(nonce), invite_nonce_expires_at: 1.day.from_now)
  end
  let(:nonce) { "c" * 64 }
  let(:provider) { instance_double(ClerkInvitationService, configured?: true) }
  let(:headers) { { "Authorization" => "Bearer valid.token" } }

  before do
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => actor.clerk_id)
    allow(ClerkInvitationService).to receive(:new).and_return(provider)
  end

  def resend
    post "/api/v1/admin/users/#{invitee.id}/resend_invitation", headers: headers
  end

  def recover(subject = "user_recovery")
    post "/api/v1/admin/users/#{invitee.id}/bind_clerk_id", headers: headers, params: { clerk_id: subject }
  end

  it "attaches a new digest and metadata when creating a staff user" do
    expect(provider).to receive(:create_invitation) do |email:, redirect_url:, public_metadata:, ignore_existing:|
      user = User.find(public_metadata.fetch(:payroll_user_id))
      expect(user).to have_attributes(email: email, invitation_status: "pending", role: "manager")
      expect(redirect_url).to end_with("/login")
      expect(ignore_existing).to be(false)
      expect(public_metadata.fetch(:payroll_invite_nonce)).to match(/\A[0-9a-f]{64}\z/)
      { success: true, invitation_id: "inv_new" }
    end

    post "/api/v1/admin/users", headers: headers, params: { user: { email: "new-staff@example.test", role: "manager" } }

    expect(response).to have_http_status(:created)
    expect(User.find(response.parsed_body.dig("data", "id"))).to have_attributes(
      clerk_invitation_id: "inv_new", invite_nonce_digest: be_present, invite_nonce_expires_at: be_future)
  end

  it "rotates the nonce only after confirming the unaccepted invitation was revoked" do
    allow(provider).to receive(:invitation_status).with("inv_original").and_return("pending")
    expect(provider).to receive(:revoke_invitation).with("inv_original").ordered.and_return(success: true)
    replacement_nonce = nil
    expect(provider).to receive(:create_invitation).ordered do |**args|
      expect(args).to include(email: invitee.email, ignore_existing: true)
      expect(args.fetch(:public_metadata)).to include(payroll_user_id: invitee.id)
      replacement_nonce = args.fetch(:public_metadata).fetch(:payroll_invite_nonce)
      { success: true, invitation_id: "inv_replacement" }
    end

    resend

    expect(response).to have_http_status(:ok)
    expect(replacement_nonce).not_to eq(nonce)
    expect(invitee.reload).to have_attributes(clerk_invitation_id: "inv_replacement",
      invite_nonce_digest: Digest::SHA256.hexdigest(replacement_nonce))
  end

  it "preserves an accepted invitation on resend and the existing Clerk user still binds" do
    allow(provider).to receive(:invitation_status).with("inv_original").and_return("accepted")
    expect(provider).not_to receive(:revoke_invitation)
    expect(provider).not_to receive(:create_invitation)
    old_expiry = invitee.invite_nonce_expires_at

    resend

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["invitation_error"]).to include("already accepted")
    expect(invitee.reload).to have_attributes(clerk_invitation_id: "inv_original",
      invite_nonce_digest: Digest::SHA256.hexdigest(nonce), invite_nonce_expires_at: old_expiry)

    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => "user_invitee")
    allow(provider).to receive(:fetch_user).with("user_invitee").and_return(
      "id" => "user_invitee", "public_metadata" => { "payroll_user_id" => invitee.id, "payroll_invite_nonce" => nonce })

    get "/api/v1/auth/me", headers: headers

    expect(response).to have_http_status(:ok)
    expect(invitee.reload.clerk_id).to eq("user_invitee")
  end

  it "keeps the nonce if acceptance wins the race against revocation" do
    allow(provider).to receive(:invitation_status).with("inv_original").and_return("pending")
    expect(provider).to receive(:revoke_invitation).with("inv_original")
      .and_return(success: false, error_code: "invitation_already_accepted")
    expect(provider).not_to receive(:create_invitation)

    expect { resend }.not_to change { invitee.reload.invite_nonce_digest }

    expect(response.parsed_body["invitation_error"]).to include("already accepted")
  end

  it "keeps the previous binding data when Clerk status is unknown" do
    allow(provider).to receive(:invitation_status).with("inv_original").and_return(nil)
    expect(provider).not_to receive(:revoke_invitation)
    expect(provider).not_to receive(:create_invitation)

    expect { resend }.not_to change { invitee.reload.attributes.slice("invite_nonce_digest", "clerk_invitation_id") }

    expect(response.parsed_body["invitation_error"]).to include("Could not confirm")
  end

  it "binds a verified subject with an audit attributed to the operator" do
    allow(provider).to receive(:fetch_user).with("user_recovery").and_return("id" => "user_recovery")

    expect { recover }.to change(AuditLog.where(action: "authentication#clerk_identity_bound"), :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(invitee.reload).to have_attributes(clerk_id: "user_recovery", invitation_status: "accepted",
      invite_nonce_digest: nil, invite_nonce_expires_at: nil)
    expect(AuditLog.find_by!(action: "authentication#clerk_identity_bound")).to have_attributes(
      user_id: actor.id, record_id: invitee.id, event_category: "security",
      metadata: { "source" => "staff_recovery", "clerk_id" => "user_recovery" })
  end

  it "refuses legacy admins before any Clerk read" do
    actor.update!(role: :admin)
    expect(provider).not_to receive(:fetch_user)

    recover

    expect(response).to have_http_status(:forbidden)
    expect(invitee.reload.clerk_id).to eq("pending_invitee")
  end

  it "refuses recovery across organizations before any Clerk read" do
    foreign = create(:user, role: :org_admin, clerk_id: "user_foreign")
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => foreign.clerk_id)
    expect(provider).not_to receive(:fetch_user)

    recover

    expect(response).to have_http_status(:not_found)
  end

  it "refuses missing and already-bound Clerk subjects" do
    allow(provider).to receive(:fetch_user).with("user_missing").and_return(nil)
    allow(provider).to receive(:fetch_user).with(actor.clerk_id).and_return("id" => actor.clerk_id)

    %W[user_missing #{actor.clerk_id}].each do |subject|
      recover(subject)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invitee.reload.clerk_id).to eq("pending_invitee")
    end
  end

  it "retires the old email invitation endpoint without queueing a legacy invite" do
    expect do
      post "/api/v1/admin/user_invitations", headers: headers, params: { invitation: { email: "legacy@example.test" } }
    end.not_to change(UserInvitation, :count)

    expect(response).to have_http_status(:gone)
  end
end
