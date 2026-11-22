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

  let(:account) do
    { id: "user_recovery", name: "Sample Recipient",
      verified_emails: [ "verified@example.test" ], primary_email: "unverified@example.test" }
  end

  def recover(subject = "user_recovery", email: "verified@example.test")
    post "/api/v1/admin/users/#{invitee.id}/bind_clerk_id", headers: headers,
      params: { clerk_id: subject, confirm_email: email }
  end

  def lookup
    post "/api/v1/admin/users/#{invitee.id}/lookup_clerk_id", headers: headers, params: { clerk_id: "user_recovery" }
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

  it "offers recovery and only returns the verified emails and display name in the preview" do
    allow(provider).to receive(:recovery_account).with("user_recovery").and_return(account)
    get "/api/v1/admin/users/#{invitee.id}", headers: headers
    expect(response.parsed_body.dig("data", "can_recover_clerk_invitation")).to be(true)

    expect { lookup }.not_to change { invitee.reload.clerk_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to eq(
      "id" => "user_recovery", "name" => "Sample Recipient", "verified_emails" => [ "verified@example.test" ])
  end

  it "lets a super admin bind an admin-level row and audits the Clerk ID and primary email" do
    actor.update!(role: :super_admin)
    invitee.update!(role: :org_admin)
    allow(provider).to receive(:recovery_account).with("user_recovery").and_return(account)
    expect(provider).to receive(:revoke_invitation).with("inv_original") do
      expect(invitee.reload.clerk_id).to eq("user_recovery")
      { success: true }
    end

    expect { recover }.to change(AuditLog.where(action: "authentication#clerk_identity_bound"), :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(invitee.reload).to have_attributes(clerk_id: "user_recovery", invitation_status: "accepted",
      clerk_invitation_id: nil, invite_nonce_digest: nil, invite_nonce_expires_at: nil)
    expect(response.parsed_body.dig("data", "can_recover_clerk_invitation")).to be(false)
    expect(AuditLog.find_by!(action: "authentication#clerk_identity_bound")).to have_attributes(
      user_id: actor.id, record_id: invitee.id, event_category: "security",
      metadata: { "source" => "staff_recovery", "clerk_id" => "user_recovery", "clerk_primary_email" => "unverified@example.test" })
  end

  it "keeps an organization admin's recovery bind when revocation fails" do
    allow(provider).to receive(:recovery_account).with("user_recovery").and_return(account)
    allow(provider).to receive(:revoke_invitation).with("inv_original").and_return(success: false, status: 503)
    allow(Rails.logger).to receive(:warn).and_call_original

    recover

    expect(response).to have_http_status(:ok)
    expect(invitee.reload).to have_attributes(clerk_id: "user_recovery", clerk_invitation_id: nil)
    expect(Rails.logger).to have_received(:warn).with(/Could not revoke invitation inv_original: 503/)
  end

  { mismatched: "stranger@example.test", unverified: "unverified@example.test", missing: nil }.each do |scenario, email|
    it "refuses a #{scenario} confirmation email" do
      allow(provider).to receive(:recovery_account).with("user_recovery").and_return(account)
      expect(provider).not_to receive(:revoke_invitation)

      expect { recover(email: email) }.not_to change { invitee.reload.clerk_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("verified email")
    end
  end

  %i[org_admin admin].each do |role|
    it "refuses lookup and recovery of a #{role} by an organization admin" do
      invitee.update!(role: role)
      expect(provider).not_to receive(:recovery_account)
      get "/api/v1/admin/users/#{invitee.id}", headers: headers
      expect(response.parsed_body.dig("data", "can_recover_clerk_invitation")).to be(false)

      lookup
      expect(response).to have_http_status(:unprocessable_entity)
      expect { recover }.not_to change { invitee.reload.clerk_id }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  [ :not_found, "expired" ].each do |status|
    it "resends when the previous invitation is #{status}" do
      allow(provider).to receive(:invitation_status).with("inv_original").and_return(status)
      expect(provider).not_to receive(:revoke_invitation)
      expect(provider).to receive(:create_invitation).and_return(success: true, invitation_id: "inv_replacement")

      expect { resend }.to change { invitee.reload.clerk_invitation_id }.from("inv_original").to("inv_replacement")

      expect(response).to have_http_status(:ok)
      expect(invitee.invite_nonce_digest).not_to eq(Digest::SHA256.hexdigest(nonce))
    end
  end

  [ nil, "" ].each do |clerk_id|
    it "issues a fresh nonce invite for a pending row with clerk_id #{clerk_id.inspect}" do
      invitee.update!(clerk_id: clerk_id, clerk_invitation_id: nil)
      expect(provider).to receive(:create_invitation) do |**args|
        expect(args.fetch(:public_metadata)).to include(payroll_user_id: invitee.id)
        expect(args.fetch(:public_metadata).fetch(:payroll_invite_nonce)).not_to eq(nonce)
        { success: true, invitation_id: "inv_replacement" }
      end

      expect { resend }.to change { invitee.reload.invite_nonce_digest }

      expect(response).to have_http_status(:ok)
      expect(invitee.clerk_invitation_id).to eq("inv_replacement")
    end
  end

  it "revokes the new invite when a local validation prevents its save" do
    invitee.update_columns(name: "", clerk_invitation_id: nil)
    expect(provider).to receive(:create_invitation).and_return(success: true, invitation_id: "inv_new")
    expect(provider).to receive(:revoke_invitation).with("inv_new", email: invitee.email).and_return(success: true)

    resend

    expect(response.parsed_body["invitation_error"]).to include("could not be saved locally")
    expect(invitee.reload.clerk_invitation_id).to be_nil
  end

  it "revokes the losing invitation if the row binds while Clerk creates it" do
    invitee.update!(clerk_invitation_id: nil)
    expect(provider).to receive(:create_invitation) do
      User.find(invitee.id).update!(clerk_id: "user_concurrent", invitation_status: "accepted")
      { success: true, invitation_id: "inv_losing" }
    end
    expect(provider).to receive(:revoke_invitation).with("inv_losing", email: invitee.email).and_return(success: true)

    resend

    expect(response.parsed_body["invitation_error"]).to include("account changed")
    expect(invitee.reload).to have_attributes(clerk_id: "user_concurrent", clerk_invitation_id: nil)
  end

  it "does not bind from metadata if the invitation rotates during the Clerk status check" do
    allow(provider).to receive(:fetch_user).with("user_invitee").and_return(
      "public_metadata" => { "payroll_user_id" => invitee.id, "payroll_invite_nonce" => nonce })
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => "user_invitee")
    expect(provider).to receive(:invitation_status).with("inv_original") do
      User.find(invitee.id).update!(clerk_invitation_id: "inv_rotated", invite_nonce_digest: Digest::SHA256.hexdigest("d" * 64))
      "accepted"
    end

    get "/api/v1/auth/me", headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(invitee.reload).to have_attributes(clerk_id: "pending_invitee", clerk_invitation_id: "inv_rotated")
  end

  %w[employee portal_employee].each do |role|
    it "refuses to create or assign the gated #{role} role" do
      actor.update!(role: :super_admin)
      expect(provider).not_to receive(:create_invitation)

      post "/api/v1/admin/users", headers: headers, params: { user: { role: role, email: "new@example.test" } }
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/admin/users/#{invitee.id}", headers: headers, params: { user: { role: role } }
      expect(response).to have_http_status(:forbidden)
      expect(invitee.reload).to be_client
    end
  end

  it "refuses legacy admins before any Clerk read" do
    actor.update!(role: :admin)
    expect(provider).not_to receive(:recovery_account)

    recover

    expect(response).to have_http_status(:forbidden)
    expect(invitee.reload.clerk_id).to eq("pending_invitee")
  end

  it "refuses recovery across organizations before any Clerk read" do
    foreign = create(:user, role: :org_admin, clerk_id: "user_foreign")
    allow_any_instance_of(ClerkTokenVerifier).to receive(:verify).and_return("sub" => foreign.clerk_id)
    expect(provider).not_to receive(:recovery_account)

    recover

    expect(response).to have_http_status(:not_found)
  end

  it "refuses missing and already-bound Clerk subjects" do
    allow(provider).to receive(:recovery_account).with("user_missing").and_return(nil)
    allow(provider).to receive(:recovery_account).with(actor.clerk_id).and_return(account.merge(id: actor.clerk_id))
    expect(provider).not_to receive(:revoke_invitation)

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
