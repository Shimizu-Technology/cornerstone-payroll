# frozen_string_literal: true

# Real Clerk token verification for employee app request specs: tokens are
# signed with a local key and checked by ClerkTokenVerifier against its JWKS.
# Only Clerk's Backend API (ClerkInvitationService) is a double.
module EmployeeLinkHelpers
  TEST_TERMS_VERSION = "request-test-v1"
  ISSUER = "https://clerk.employee-links.example.test"
  PAYROLL_ORIGIN = "https://payroll.example.test"
  APP_URL = "https://employees.example.test"

  def self.included(base)
    base.let(:link_signing_key) { OpenSSL::PKey::RSA.generate(2048) }
    base.let(:link_jwk) { JWT::JWK.new(link_signing_key) }
    base.let(:clerk) { instance_double(ClerkInvitationService, configured?: true) }
    base.let(:clerk_invitations) { [] }

    base.before do
      EmployeeTermsVersion.create!(version: TEST_TERMS_VERSION, status: "draft", terms_url: "/terms",
        privacy_url: "/privacy", published_at: Time.current)
      verifier = ClerkTokenVerifier.new(
        env: { "CLERK_ISSUER" => ISSUER, "CLERK_AUTHORIZED_PARTIES" => PAYROLL_ORIGIN },
        cache: ActiveSupport::Cache::MemoryStore.new,
        http_get: ->(_uri) { [ 200, { "keys" => [ link_jwk.export.deep_stringify_keys ] } ] }
      )
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
      allow(ClerkInvitationService).to receive(:new).and_return(clerk)
      allow(clerk).to receive(:create_invitation) do |**options|
        clerk_invitations << options
        { success: true, invitation_id: "inv_#{clerk_invitations.length}", status: "pending",
          url: "https://accounts.example.test/accept/#{clerk_invitations.length}" }
      end
      allow(clerk).to receive(:invitation_status) { |id| id.present? ? "pending" : nil }
      allow(clerk).to receive(:revoke_invitation).and_return(success: true)
      allow(clerk).to receive(:fetch_user).and_return(nil)
      allow(clerk).to receive(:users_with_email).and_return([])
      allow(clerk).to receive(:revoke_user_sessions).and_return(success: true, revoked: 0)
      allow(clerk).to receive(:delete_user).and_return(success: true)
      # The session fence reads a reactivated login's session from Clerk;
      # unknown sessions fail closed. Specs register them (clerk_session!).
      allow(clerk).to receive(:fetch_session).and_return(nil)
    end

    base.around do |example|
      previous = ENV["EMPLOYEE_APP_URL"]
      ENV["EMPLOYEE_APP_URL"] = APP_URL
      example.run
    ensure
      ENV["EMPLOYEE_APP_URL"] = previous
    end
  end

  def clerk_token(subject, azp: PAYROLL_ORIGIN, fva: [ 0, -1 ], **claims)
    payload = { sub: subject, iss: ISSUER, azp: azp, iat: Time.current.to_i, exp: 5.minutes.from_now.to_i, fva: fva,
                sid: "sess_#{subject}" }
    JWT.encode(payload.merge(claims), link_signing_key, "RS256", kid: link_jwk.kid)
  end

  # What Clerk's Backend API reports for a session (SessionFence).
  def clerk_session!(sid, user_id:, created_at:)
    allow(clerk).to receive(:fetch_session).with(sid).and_return(
      "id" => sid, "user_id" => user_id, "status" => "active", "created_at" => (created_at.to_r * 1000).floor
    )
  end

  def bearer(subject, **options)
    { "Authorization" => "Bearer #{clerk_token(subject, **options)}" }
  end

  def enable_employee_app!(company, subdomain: false)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: true, options: { subdomain_enabled: subdomain }
    )
    activate_employee_app!(company)
  end

  # Runs the way a staff controller does: a company scope, with the RLS guard
  # checking every query.
  def as_staff_in(company, &block)
    RlsSpecContext.strict { TenantScope.with_company(company.id, &block) }
  end

  def invite!(employee, actor:, delivery: "email", **options)
    as_staff_in(employee.company) do
      EmployeeLinks::Invite.call(employee: employee, actor: actor, delivery: delivery, **options)
    end
  end

  def activation_params(employee, **overrides)
    { date_of_birth: employee.date_of_birth.iso8601, ssn_last4: employee.ssn_digits.last(4),
      email: "own.address@example.net", terms_version: TEST_TERMS_VERSION }.merge(overrides)
  end

  # origin: the browser Origin the sign-up page sends (a client subdomain).
  def post_activation(params, headers: {}, origin: nil)
    request_headers = { "CONTENT_TYPE" => "application/json" }
    request_headers["Origin"] = origin if origin
    post "/api/v1/employee/activation", params: { terms_version: TEST_TERMS_VERSION }.merge(params).to_json, headers: request_headers.merge(headers)
  end

  # What Clerk reports once the person finishes sign-up with the invitation:
  # an account for the invited address, verified by the invitation ticket
  # unless the spec says otherwise.
  def accept_clerk_invitation!(subject, invitation_index: -1, email: nil, strategy: "ticket", status: "verified")
    options = clerk_invitations.fetch(invitation_index)
    address = email || options.fetch(:email)
    allow(clerk).to receive(:fetch_user).with(subject).and_return(
      "id" => subject, "public_metadata" => options.fetch(:public_metadata).deep_stringify_keys,
      "primary_email_address_id" => "idn_#{subject}",
      "email_addresses" => [ { "id" => "idn_#{subject}", "email_address" => address,
                               "verification" => { "status" => status, "strategy" => strategy } } ]
    )
    index = invitation_index.negative? ? clerk_invitations.length + invitation_index : invitation_index
    allow(clerk).to receive(:invitation_status).with("inv_#{index + 1}").and_return("accepted")
  end

  # Starting an account and being sent to sign in share one status (200).
  def expect_sign_up_started
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("next" => "sign_up", "message" => nil)
    expect(response.parsed_body["sign_up_url"]).to be_present
  end

  def link_audits(link, action)
    AuditLog.where(record_type: "employee_account_links", record_id: link.id, action: "employee_links##{action}").order(:id)
  end
end
