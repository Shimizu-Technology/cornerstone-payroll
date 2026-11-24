# frozen_string_literal: true

# Real Clerk token verification for employee app request specs: tokens are
# signed with a local key and checked by ClerkTokenVerifier against its JWKS.
# Only Clerk's Backend API (ClerkInvitationService) is a double.
module EmployeeLinkHelpers
  ISSUER = "https://clerk.employee-links.example.test"
  PAYROLL_ORIGIN = "https://payroll.example.test"
  APP_URL = "https://employees.example.test"

  def self.included(base)
    base.let(:link_signing_key) { OpenSSL::PKey::RSA.generate(2048) }
    base.let(:link_jwk) { JWT::JWK.new(link_signing_key) }
    base.let(:clerk) { instance_double(ClerkInvitationService, configured?: true) }
    base.let(:clerk_invitations) { [] }

    base.before do
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
    payload = { sub: subject, iss: ISSUER, azp: azp, exp: 5.minutes.from_now.to_i, fva: fva, sid: "sess_#{subject}" }
    JWT.encode(payload.merge(claims), link_signing_key, "RS256", kid: link_jwk.kid)
  end

  def bearer(subject, **options)
    { "Authorization" => "Bearer #{clerk_token(subject, **options)}" }
  end

  def enable_employee_app!(company, subdomain: false)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service", hours_source: "manual",
      employee_portal_enabled: true, options: { subdomain_enabled: subdomain }
    )
    TenantSubdomainRegistry.invalidate!
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
      email: "own.address@example.net" }.merge(overrides)
  end

  def post_activation(params, headers: {})
    post "/api/v1/employee/activation", params: params.to_json,
      headers: { "CONTENT_TYPE" => "application/json" }.merge(headers)
  end

  # What Clerk reports once the person finishes sign-up with the invitation.
  def accept_clerk_invitation!(subject, invitation_index: -1)
    options = clerk_invitations.fetch(invitation_index)
    allow(clerk).to receive(:fetch_user).with(subject).and_return(
      "id" => subject, "public_metadata" => options.fetch(:public_metadata).deep_stringify_keys
    )
    invitation_id = "inv_#{clerk_invitations.length + invitation_index + 1}"
    allow(clerk).to receive(:invitation_status).with(invitation_id).and_return("accepted")
  end

  def link_audits(link, action)
    AuditLog.where(record_type: "employee_account_links", record_id: link.id, action: "employee_links##{action}").order(:id)
  end
end
