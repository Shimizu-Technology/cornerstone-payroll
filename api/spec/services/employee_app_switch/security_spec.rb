# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# M4-9d security review follow-ups: the live signed health answer, the
# current-process guard for demos under the early-access waiver, demo
# request origins, and durable Clerk revocations.
RSpec.describe "Employee app switch security" do
  let(:secret) { "s" * 48 }
  let(:env) { { EmployeeAppSwitch::ServiceAttestation::SECRET_ENV => secret, "APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB } }
  let(:attestation) { EmployeeAppSwitch::ServiceAttestation }
  let(:service_readiness) { -> { instance_double(ProductionReadiness, employee_service_checks: []) } }

  def signed(nonce, now: Time.current, sign_env: env)
    allow(attestation).to receive(:process_database_facts).and_return([ true, false ])
    attestation.sign(nonce: nonce, dependencies_healthy: true, env: sign_env.merge("RLS_CONTEXT_GUARD_MODE" => "raise"),
      now: now, readiness: service_readiness)
  end

  describe EmployeeAppSwitch::ServiceAttestation do
    it "accepts the employee service's signed answer for this nonce" do
      nonce = attestation.new_nonce
      body = { status: "ok", attestation: signed(nonce) }.to_json
      observation, error = attestation.verify(body, nonce: nonce, env: env)
      expect(error).to be_nil
      expect(observation).to have_attributes(rls_guard_mode: "raise", rls_runtime_role_verified: true, rls_kill_switch_bypass: false,
        process_role: "employee_web", dependencies_healthy: true)
      expect(observation.rls_guard_raise?).to be(true)
    end

    it "rejects a spoofed, replayed, stale or foreign answer" do
      nonce = attestation.new_nonce
      good = signed(nonce)

      spoofed = good.merge(statement: good[:statement].sub('"rls_guard_mode":"raise"', '"rls_guard_mode":"raise" '))
      expect(attestation.verify({ attestation: spoofed }.to_json, nonce: nonce, env: env)).to eq([ nil, :bad_signature ])

      forged = signed(nonce, sign_env: env.merge(attestation::SECRET_ENV => "x" * 48))
      expect(attestation.verify({ attestation: forged }.to_json, nonce: nonce, env: env)).to eq([ nil, :bad_signature ])

      expect(attestation.verify({ attestation: good }.to_json, nonce: attestation.new_nonce, env: env)).to eq([ nil, :bad_signature ])
      expect(attestation.verify({ status: "ok" }.to_json, nonce: nonce, env: env)).to eq([ nil, :unsigned ])
      expect(attestation.verify("<html>", nonce: nonce, env: env)).to eq([ nil, :unsigned ])

      old = signed(nonce, now: 5.minutes.ago)
      expect(attestation.verify({ attestation: old }.to_json, nonce: nonce, env: env)).to eq([ nil, :stale ])

      expect(signed(nonce, sign_env: env.merge("APP_PROCESS_ROLE" => ProcessRole::PAYROLL_WEB))).to be_nil
      expect(attestation.verify({ attestation: good }.to_json, nonce: nonce, env: {})).to eq([ nil, :not_configured ])
    end

    it "answers only a caller that proves it holds the secret" do
      nonce = attestation.new_nonce
      headers = attestation.request_headers(nonce, env: env)
      expect(attestation.valid_request?(nonce, headers[attestation::PROOF_HEADER], env: env)).to be(true)
      expect(attestation.valid_request?(nonce, "0" * 64, env: env)).to be(false)
      expect(attestation.valid_request?(attestation.new_nonce, headers[attestation::PROOF_HEADER], env: env)).to be(false)
      expect(attestation.valid_request?(nonce, headers[attestation::PROOF_HEADER], env: { attestation::SECRET_ENV => "short" })).to be(false)
    end
  end

  describe "the live ping from Payroll" do
    let(:base) { "https://employees-api.example.test" }
    let(:ping_env) { env.merge("EMPLOYEE_API_URL" => base) }

    it "uses the live signed answer, and rejects a spoofed one or a redirect" do
      stub_request(:get, "#{base}/health/dependencies").to_return do |request|
        nonce = request.headers[attestation::NONCE_HEADER.split("-").map(&:capitalize).join("-")]
        { status: 200, body: { status: "ok", attestation: signed(nonce) }.to_json, headers: { "Content-Type" => "application/json" } }
      end
      result = EmployeeAppSwitch::Readiness.ping_employee_service(ping_env)
      expect(result).to include(configured: true, ok: true, attestation_error: nil)
      expect(result[:observation].rls_guard_mode).to eq("raise")

      stub_request(:get, "#{base}/health/dependencies").to_return(status: 200,
        body: { status: "ok", attestation: { statement: { nonce: "x", rls_guard_mode: "raise" }.to_json, signature: "a" * 64 } }.to_json)
      expect(EmployeeAppSwitch::Readiness.ping_employee_service(ping_env)).to include(ok: true, observation: nil, attestation_error: :bad_signature)

      stub_request(:get, "#{base}/health/dependencies").to_return(status: 302, headers: { "Location" => "https://elsewhere.example.test/" })
      expect(EmployeeAppSwitch::Readiness.ping_employee_service(ping_env)).to include(ok: false, observation: nil)
    end

    it "only reads a configured HTTPS URL in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(EmployeeAppSwitch::Readiness.employee_health_uri("http://employees-api.example.test")).to be_nil
      expect(EmployeeAppSwitch::Readiness.employee_health_uri("https://employees-api.example.test").to_s)
        .to eq("https://employees-api.example.test/health/dependencies")
    end
  end

  describe Health::DependenciesController, type: :request do
    around do |example|
      saved = ENV[attestation::SECRET_ENV]
      ENV[attestation::SECRET_ENV] = secret
      example.run
    ensure
      ENV[attestation::SECRET_ENV] = saved
    end

    before do
      # Routes are drawn on the first request from APP_PROCESS_ROLE, so the
      # employee_web role is handed to the signer rather than set in ENV.
      allow(attestation).to receive(:sign).and_wrap_original do |original, **options|
        original.call(**options, env: ENV.to_h.merge("APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB))
      end
      allow(attestation).to receive(:process_database_facts).and_return([ true, false ])
      allow(DependencyHealth).to receive(:new).and_return(instance_double(DependencyHealth, run: instance_double(DependencyHealth::Report, ready?: true)))
      allow(ProductionReadiness).to receive(:new).and_return(instance_double(ProductionReadiness, employee_service_checks: []))
    end

    it "signs its own process facts only for a caller with the secret" do
      get "/health/dependencies"
      expect(response.parsed_body).to eq("status" => "ok")

      nonce = attestation.new_nonce
      get "/health/dependencies", headers: attestation.request_headers(nonce)
      observation, error = attestation.verify(response.body, nonce: nonce)
      expect(error).to be_nil
      expect(observation.process_role).to eq("employee_web")

      get "/health/dependencies", headers: { attestation::NONCE_HEADER => nonce, attestation::PROOF_HEADER => "f" * 64 }
      expect(response.parsed_body).not_to have_key("attestation")
    end
  end

  describe EmployeeAppSwitch::Enforcement do
    let(:organization) { create(:organization) }
    let(:demo) { create_demo_company(organization: organization, subdomain_slug: "harborfinch") }
    let(:live) { create(:company, organization: organization) }

    before { allow(described_class).to receive(:verified?).and_return(false) }

    it "lets a demo under the waiver through only on a guarded process" do
      expect(described_class.demo_request_allowed?(live)).to be(true)
      expect(described_class.demo_request_allowed?(demo)).to be(false)

      guard = { "RLS_CONTEXT_GUARD_MODE" => "raise", "RLS_DATABASE_URL" => "postgres://payroll_app@db.example.test/payroll" }
      allow(RlsDatabase).to receive(:verify_runtime!).and_return(true)
      allow(RlsDatabase).to receive(:bypass_enabled?).and_return(false)
      expect(described_class.current_process_guarded?(env: guard)).to be(true)
      expect(described_class.current_process_guarded?(env: guard.merge("RLS_CONTEXT_GUARD_MODE" => "log"))).to be(false)

      allow(RlsDatabase).to receive(:bypass_enabled?).and_return(true)
      expect(described_class.current_process_guarded?(env: guard)).to be(false)

      described_class.reset_cache!
      allow(RlsDatabase).to receive(:bypass_enabled?).and_return(false)
      allow(RlsDatabase).to receive(:verify_runtime!).and_raise("not the restricted role")
      expect(described_class.current_process_guarded?(env: guard)).to be(false)

      allow(described_class).to receive(:verified?).and_return(true)
      expect(described_class.demo_request_allowed?(demo)).to be(true)
    end

    it "requires a demo link's activation, claim and bind to come from its own subdomain" do
      allow(described_class).to receive(:demo_request_allowed?).and_return(true)
      allow(TenantSubdomainRegistry).to receive(:enabled_origin_company_id) do |origin|
        origin == "https://harborfinch.cornerstone-payroll.example" ? demo.id : nil
      end
      allow(TenantSubdomainRegistry).to receive(:client_origin?) { |origin| origin.to_s.start_with?("https://harborfinch") }

      expect(EmployeeLinks.demo_request_allowed?(demo, "https://harborfinch.cornerstone-payroll.example")).to be(true)
      expect(EmployeeLinks.demo_request_allowed?(demo, "https://employees.example.test")).to be(false)
      expect(EmployeeLinks.demo_request_allowed?(demo, nil)).to be(false)
      expect(EmployeeLinks.demo_request_allowed?(live, nil)).to be(true)

      allow(described_class).to receive(:demo_request_allowed?).and_return(false)
      expect(EmployeeLinks.demo_request_allowed?(demo, "https://harborfinch.cornerstone-payroll.example")).to be(false)
    end
  end

  describe RevokeEmployeeAppClerkJob do
    include ActiveJob::TestHelper

    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }
    let(:admin) { create(:user, company: company, organization: organization, role: :org_admin) }
    let(:login) { create(:user, company: company, organization: organization, clerk_id: "user_employee_1") }
    let(:clerk) { instance_double(ClerkInvitationService) }

    def request!(kind, target, user: nil)
      TenantScope.as_system(reason: "spec") do
        EmployeeAppClerkRevocation.request!(kind: kind, target: target, organization: organization, company: company,
          source: EmployeeAppClerkRevocation::SOURCE_DEMO_STOP, requested_by: admin, user: user)
      end
    end

    before { allow(ClerkInvitationService).to receive(:new).and_return(clerk) }

    it "keeps one pending request per target and allows a new one once confirmed" do
      first = request!("sessions", login.id, user: login)
      expect(first).to be_persisted
      expect(request!("sessions", login.id, user: login)).to be_nil
      first.update!(confirmed_at: Time.current)
      expect(request!("sessions", login.id, user: login)).to be_persisted
    end

    it "retries until Clerk confirms, then audits the confirmation separately" do
      revocation = request!("sessions", login.id, user: login)
      allow(clerk).to receive(:revoke_user_sessions).and_return({ success: false, error: "Clerk down" }, { success: true })

      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(attempts: 1, last_error: "Clerk down", confirmed_at: nil)
      expect(described_class).to have_been_enqueued.with(revocation.id)

      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(attempts: 2, last_error: nil)
      expect(revocation.confirmed_at).to be_present
      audit = AuditLog.find_by!(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)
      expect(audit.metadata).to include("kind" => "sessions", "source" => "demo_stop", "attempts" => 2)

      described_class.perform_now(revocation.id)
      expect(clerk).to have_received(:revoke_user_sessions).twice
    end

    it "treats an invitation that is already closed as confirmed, and records giving up" do
      closed = request!("invitation", "inv_closed")
      allow(clerk).to receive(:invitation_status).with("inv_closed").and_return("revoked")
      described_class.perform_now(closed.id)
      expect(closed.reload.confirmed_at).to be_present

      stuck = request!("invitation", "inv_stuck")
      allow(clerk).to receive(:invitation_status).with("inv_stuck").and_return("pending")
      allow(clerk).to receive(:revoke_invitation).and_return(success: false, error: "nope")
      job = described_class.new(stuck.id)
      TenantScope.as_system(reason: "spec") { job.give_up!(RevokeEmployeeAppClerkJob::RevocationFailed.new("nope")) }
      expect(stuck.reload.gave_up_at).to be_present
      expect(AuditLog.where(action: described_class::GAVE_UP_ACTION, record_id: stuck.id).count).to eq(1)
    end
  end
end
