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

    it "counts only the employee service's own checks: not intentionally-off MFA or the payroll tax tables" do
      service_env = env.merge(
        "RAILS_ENV" => "production", "DB_POOL_MAX" => "3", "RACK_ATTACK_REDIS_URL" => "rediss://redis.example.test:6380",
        "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.com"
      )
      readiness = ProductionReadiness.new(
        env: service_env, process_role: -> { ProcessRole::EMPLOYEE_WEB }, route_paths: -> { [ "/up(.:format)", "/api/v1/employee/context(.:format)" ] },
        cable_mount_path: -> { nil }, primary_pool_size: -> { 3 },
        rate_limit_store: -> { RackAttackStore::Failover.new(ActiveSupport::Cache::NullStore.new, ActiveSupport::Cache::MemoryStore.new) },
        tax_year_readiness: -> { { warnings: [ { tax_year: 2027, message: "2027 tax tables are not verified yet." } ] } }
      )
      report = readiness.run(live: false)
      expect(report.failures.map(&:name)).to include("2027 payroll tax tables are verified")
      expect(report.warnings.map(&:name)).to include("MFA enforcement has instance-bound evidence")
      expect(readiness.employee_service_checks.map(&:name)).to all(start_with("employee_web: "))
      expect(readiness.employee_service_checks).to all(have_attributes(passed: true))

      nonce = attestation.new_nonce
      allow(attestation).to receive(:process_database_facts).and_return([ true, false ])
      body = { attestation: attestation.sign(nonce: nonce, dependencies_healthy: true, env: service_env, readiness: -> { readiness }) }.to_json
      observation, = attestation.verify(body, nonce: nonce, env: env)
      expect(observation).to have_attributes(service_checks_passed: true, failed_checks: [], require_mfa: false, mfa_evidence_recorded: false)
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

    let(:shadow) { { phase: "shadow", enforced: false, kill_switch_bypass: false } }

    before do
      allow(described_class).to receive(:verified?).and_return(false)
      allow(described_class).to receive(:database_state).and_return(shadow)
    end

    it "lets a demo under the waiver through only on a guarded process" do
      expect(described_class.demo_request_allowed?(live)).to be(true)
      expect(described_class.demo_request_allowed?(demo)).to be(false)

      guard = { "RLS_CONTEXT_GUARD_MODE" => "raise", "RLS_DATABASE_URL" => "postgres://payroll_app@db.example.test/payroll" }
      allow(RlsDatabase).to receive(:verify_runtime!).and_return(true)
      allow(RlsDatabase).to receive(:bypass_state).and_return(false)
      expect(described_class.current_process_guarded?(env: guard)).to be(true)
      expect(described_class.current_process_guarded?(env: guard.merge("RLS_CONTEXT_GUARD_MODE" => "log"))).to be(false)

      allow(RlsDatabase).to receive(:bypass_state).and_return(true)
      expect(described_class.current_process_guarded?(env: guard)).to be(false)
      # A missing kill switch row is unknown, never "off".
      allow(RlsDatabase).to receive(:bypass_state).and_return(nil)
      expect(described_class.current_process_guarded?(env: guard)).to be(false)

      described_class.reset_cache!
      allow(RlsDatabase).to receive(:bypass_state).and_return(false)
      allow(RlsDatabase).to receive(:verify_runtime!).and_raise("not the restricted role")
      expect(described_class.current_process_guarded?(env: guard)).to be(false)

      allow(described_class).to receive(:verified?).and_return(true)
      expect(described_class.demo_request_allowed?(demo)).to be(true)
    end

    it "accepts the waiver only in the intended shadow state" do
      allow(described_class).to receive(:current_process_guarded?).and_return(true)
      expect(described_class.demo_request_allowed?(demo)).to be(true)

      [ shadow.merge(phase: "partial"), shadow.merge(phase: "unknown", kill_switch_bypass: nil),
        shadow.merge(phase: "bypassed", kill_switch_bypass: true), shadow.merge(kill_switch_bypass: nil),
        shadow.merge(phase: "not_installed") ].each do |state|
        described_class.reset_cache!
        allow(described_class).to receive(:database_state).and_return(state)
        expect(described_class.waiver_state?).to be(false), state.inspect
        expect(described_class.demo_request_allowed?(demo)).to be(false), state.inspect
      end
    end

    it "uses the full gate for every reader: window, shadow state and a guarded process" do
      EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ demo.id ],
        expires_on: PayrollBusinessClock.today + 3, reason: "Owner approved", set_by: create(:user, company: live, organization: organization, role: :super_admin))
      allow(described_class).to receive(:current_process_guarded?).and_return(false)
      expect(described_class.demo_open?(demo)).to be(true)
      expect(described_class.demo_app_open?(demo)).to be(false)

      allow(described_class).to receive(:current_process_guarded?).and_return(true)
      expect(described_class.demo_app_open?(demo)).to be(true)
      expect(described_class.demo_app_open?(live)).to be(true)
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
    include ActiveSupport::Testing::TimeHelpers

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

    # The job a claim queued for the row (the only one allowed to act on it).
    def owning_job(revocation)
      described_class.new(revocation.id).tap { |job| job.job_id = revocation.reload.job_id }
    end

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

    it "never counts an accepted invitation as revoked: it ends the resulting account's sessions" do
      bound = request!("invitation", "inv_bound", user: login)
      allow(clerk).to receive(:invitation_status).with("inv_bound").and_return("accepted")
      allow(clerk).to receive(:revoke_user_sessions).and_return({ success: false, error: "Clerk down" }, { success: true })

      described_class.perform_now(bound.id)
      expect(bound.reload).to have_attributes(confirmed_at: nil, last_error: "Clerk down")
      described_class.perform_now(bound.id)
      expect(bound.reload).to have_attributes(outcome: "accepted_sessions_revoked")
      expect(bound.confirmed_at).to be_present
      expect(clerk).to have_received(:revoke_user_sessions).with("user_employee_1", created_before: nil, email: nil).twice

      # Accepted but not bound yet: the one Clerk account with the invited address.
      pending = create(:user, company: company, organization: organization, clerk_id: "pending_abc", email: "pending.one@example.test")
      unbound = request!("invitation", "inv_unbound", user: pending)
      allow(clerk).to receive(:invitation_status).with("inv_unbound").and_return("accepted")
      allow(clerk).to receive(:users_with_email).with("pending.one@example.test").and_return([ { "id" => "user_new_account" } ])
      allow(clerk).to receive(:revoke_user_sessions).with("user_new_account", created_before: nil, email: "pending.one@example.test")
        .and_return({ success: true })
      described_class.perform_now(unbound.id)
      expect(unbound.reload).to have_attributes(outcome: "accepted_sessions_revoked")
      expect(unbound.confirmed_at).to be_present
    end

    it "ends an accepted invitation with no single account to sign out as needing follow-up, not confirmed" do
      pending = create(:user, company: company, organization: organization, clerk_id: "pending_xyz", email: "pending.two@example.test")
      revocation = request!("invitation", "inv_lost", user: pending)
      allow(clerk).to receive(:invitation_status).with("inv_lost").and_return("accepted")
      allow(clerk).to receive(:users_with_email).and_return([])

      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(confirmed_at: nil, gave_up_at: nil, outcome: "accepted_account_not_found")
      expect(revocation.follow_up_at).to be_present
      expect(revocation).not_to be_pending
      expect(AuditLog.find_by!(action: described_class::FOLLOW_UP_ACTION, record_id: revocation.id).metadata)
        .to include("outcome" => "accepted_account_not_found")
      expect(AuditLog.where(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)).to be_empty
      expect(described_class).not_to have_been_enqueued
      # A later stop may request the same target again.
      expect(request!("invitation", "inv_lost", user: pending)).to be_persisted
    end

    it "ends every session of an accepted invitation's account, however late, and confirms only once none is active" do
      previous = ENV["CLERK_SECRET_KEY"]
      ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
      allow(ClerkInvitationService).to receive(:new).and_call_original
      real = ClerkInvitationService.new
      allow(ClerkInvitationService).to receive(:new).and_return(real)
      allow(real).to receive(:invitation_status).with("inv_late").and_return("accepted")
      revocation = TenantScope.as_system(reason: "spec") do
        EmployeeAppClerkRevocation.request!(kind: "invitation", target: "inv_late", organization: organization, company: company,
          source: EmployeeAppClerkRevocation::SOURCE_DEMO_STOP, requested_by: admin, user: login, now: 2.hours.ago)
      end
      # Accepted an hour after the stop, long past the stop-based cutoff.
      late = (1.hour.ago.to_f * 1000).to_i
      listing = stub_request(:get, "https://api.clerk.com/v1/sessions")
        .with(query: { user_id: "user_employee_1", status: "active", limit: "100" })
        .to_return({ status: 200, body: [ { id: "sess_late", created_at: late } ].to_json },
          { status: 200, body: [ { id: "sess_later", created_at: late + 60_000 } ].to_json },
          { status: 200, body: [ { id: "sess_later", created_at: late + 60_000 } ].to_json },
          { status: 200, body: "[]" })
      ended = %w[sess_late sess_later].map do |id|
        stub_request(:post, "https://api.clerk.com/v1/sessions/#{id}/revoke").to_return(status: 200, body: "{}")
      end

      # A session still active on the confirming pass: not confirmed.
      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(confirmed_at: nil, last_error: "Sessions were still active after revocation")
      expect(AuditLog.where(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)).to be_empty

      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(outcome: "accepted_sessions_revoked", last_error: nil)
      expect(revocation.confirmed_at).to be_present
      expect(ended).to all(have_been_requested.once)
      expect(listing).to have_been_requested.times(4)
      expect(AuditLog.find_by!(action: described_class::CONFIRMED_ACTION, record_id: revocation.id).metadata)
        .to include("outcome" => "accepted_sessions_revoked", "sessions_ended" => 1)
    ensure
      ENV["CLERK_SECRET_KEY"] = previous
    end

    it "records a follow-up and its audit together, so a failed audit leaves the row for the retry" do
      pending = create(:user, company: company, organization: organization, clerk_id: "pending_audit", email: "pending.three@example.test")
      revocation = request!("invitation", "inv_audit", user: pending)
      allow(clerk).to receive(:invitation_status).with("inv_audit").and_return("accepted")
      allow(clerk).to receive(:users_with_email).and_return([])
      allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit write failed")

      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(follow_up_at: nil, outcome: nil, leased_until: nil, attempts: 1)
      expect(revocation).to be_pending
      expect(described_class).to have_been_enqueued.with(revocation.id)
      expect(EmployeeAppClerkRevocation.stale(1.day.from_now).ids).to include(revocation.id)

      allow(AuditLog).to receive(:record!).and_call_original
      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(outcome: "accepted_account_not_found", attempts: 2)
      expect(revocation.follow_up_at).to be_present
      expect(AuditLog.where(action: described_class::FOLLOW_UP_ACTION, record_id: revocation.id).count).to eq(1)
    end

    it "acts only as the row's owning job, one attempt at a time, and never records a second outcome" do
      revocation = request!("sessions", login.id, user: login)
      TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ revocation.id ]) }
      first_owner = owning_job(revocation)
      allow(clerk).to receive(:revoke_user_sessions).and_return({ success: true, revoked: 1 })

      # Replaced by the sweep (say the first job was only waiting in a
      # backlog): the replaced job does nothing.
      revocation.update_columns(updated_at: 7.hours.ago)
      TenantScope.as_system(reason: "spec") { RetryEmployeeAppClerkRevocationsJob.perform_now }
      expect(revocation.reload.job_id).not_to eq(first_owner.job_id)
      first_owner.perform_now
      expect(clerk).not_to have_received(:revoke_user_sessions)
      expect(revocation.reload.attempts).to eq(0)

      # An attempt in progress holds the lease: another run of the owner waits it out.
      revocation.update_columns(leased_until: 5.minutes.from_now)
      owning_job(revocation).perform_now
      expect(clerk).not_to have_received(:revoke_user_sessions)

      # An outcome recorded meanwhile (another run that finished) is never overwritten or audited twice.
      revocation.update_columns(leased_until: nil)
      allow(clerk).to receive(:revoke_user_sessions) do
        revocation.update_columns(confirmed_at: 1.minute.ago, outcome: "sessions_revoked")
        { success: true, revoked: 1 }
      end
      owning_job(revocation).perform_now
      expect(revocation.reload).to have_attributes(attempts: 1, leased_until: nil, lease_token: nil)
      expect(AuditLog.where(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)).to be_empty
    end

    # A pass that outlives its lease, while a duplicate delivery of the same
    # job takes a fresh one: the newer attempt's token fences the old run.
    def outlive_lease(revocation, owner, result)
      newer = nil
      allow(clerk).to receive(:revoke_user_sessions) do
        travel(EmployeeAppClerkRevocation::ATTEMPT_LEASE + 1.minute) do
          newer = EmployeeAppClerkRevocation.start_attempt!(revocation.id, job_id: owner.job_id)
        end
        result
      end
      owner.perform_now
      newer
    end

    it "lets a run that lost its lease record nothing and leave the newer lease alone" do
      revocation = request!("sessions", login.id, user: login)
      TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ revocation.id ]) }
      owner = owning_job(revocation)

      # Clerk confirmed, but too late: no outcome, no audit, and the newer lease still holds.
      newer = outlive_lease(revocation, owner, { success: true, revoked: 1 })
      expect(newer.lease_token).to be_present
      expect(revocation.reload).to have_attributes(confirmed_at: nil, outcome: nil, attempts: 2, lease_token: newer.lease_token)
      expect(revocation.leased_until).to be > Time.current
      expect(AuditLog.where(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)).to be_empty

      # The newer attempt still records its outcome under its own token.
      expect(revocation.finish!(job_id: owner.job_id, lease_token: newer.lease_token) { |row| row.update!(last_error: "newer") }).to be(true)
      expect(revocation.finish!(job_id: owner.job_id, lease_token: nil) { raise "never yielded" }).to be_nil
      expect(revocation.release_lease!(nil)).to eq(0)
      expect(revocation.release_lease!(newer.lease_token)).to eq(1)
      expect(revocation.reload).to have_attributes(leased_until: nil, lease_token: nil, last_error: "newer")
    end

    it "lets a run that lost its lease neither record a failure nor retry" do
      revocation = request!("sessions", login.id, user: login)
      TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ revocation.id ]) }
      owner = owning_job(revocation)
      clear_enqueued_jobs

      newer = outlive_lease(revocation, owner, { success: false, error: "Clerk down" })
      expect(revocation.reload).to have_attributes(last_error: nil, lease_token: newer.lease_token)
      expect(described_class).not_to have_been_enqueued
    end

    it "gives a run that stalls between taking its lease and reloading it nothing once a newer attempt takes over" do
      revocation = request!("sessions", login.id, user: login)
      TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ revocation.id ]) }
      owner = owning_job(revocation)
      clear_enqueued_jobs
      allow(clerk).to receive(:revoke_user_sessions).and_return({ success: true, revoked: 1 })

      # The stale run takes the lease, then pauses before reloading the row
      # until its lease has run out, and a duplicate delivery of the same job
      # (same job_id) takes a fresh lease meanwhile.
      newer = nil
      stalled = false
      allow(EmployeeAppClerkRevocation).to receive(:leased_row).and_wrap_original do |original, *args|
        unless stalled
          stalled = true
          travel(EmployeeAppClerkRevocation::ATTEMPT_LEASE + 1.minute) do
            newer = EmployeeAppClerkRevocation.start_attempt!(revocation.id, job_id: owner.job_id)
          end
        end
        original.call(*args)
      end

      owner.perform_now
      # The stale run got no row, so it never read the newer token: it
      # called nobody, recorded nothing, and left the newer lease in place.
      expect(newer.held_lease).to be_present
      expect(clerk).not_to have_received(:revoke_user_sessions)
      expect(revocation.reload).to have_attributes(confirmed_at: nil, outcome: nil, last_error: nil, attempts: 2,
        lease_token: newer.held_lease)
      expect(revocation.leased_until).to be > Time.current
      expect(AuditLog.where(action: described_class::CONFIRMED_ACTION, record_id: revocation.id)).to be_empty
      expect(described_class).not_to have_been_enqueued

      # The newer attempt keeps the token it generated, even across a reload,
      # and still finishes and releases under it.
      expect(newer.reload.held_lease).to eq(revocation.lease_token)
      expect(newer.finish!(job_id: owner.job_id, lease_token: newer.held_lease) { |row| row.update!(last_error: "newer") }).to be(true)
      expect(newer.release_lease!(newer.held_lease)).to eq(1)
      expect(revocation.reload).to have_attributes(leased_until: nil, lease_token: nil, last_error: "newer")
    end

    it "gives up only while no newer attempt holds the lease" do
      revocation = request!("sessions", login.id, user: login)
      newer = EmployeeAppClerkRevocation.start_attempt!(revocation.id, job_id: nil)
      job = described_class.new(revocation.id)
      TenantScope.as_system(reason: "spec") { job.give_up!(RevokeEmployeeAppClerkJob::RevocationFailed.new("nope")) }
      expect(revocation.reload).to have_attributes(gave_up_at: nil, lease_token: newer.lease_token)

      revocation.release_lease!(newer.lease_token)
      TenantScope.as_system(reason: "spec") { job.give_up!(RevokeEmployeeAppClerkJob::RevocationFailed.new("nope")) }
      expect(revocation.reload).to have_attributes(attempts: 1, leased_until: nil, lease_token: nil)
      expect(revocation.gave_up_at).to be_present
    end

    it "cuts a Clerk call that trickles in past the pass deadline off, and reschedules the pass" do
      stub_const("#{described_class}::PASS_DEADLINE", 0.2.seconds)
      previous = ENV["CLERK_SECRET_KEY"]
      ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
      allow(ClerkInvitationService).to receive(:new).and_call_original
      real = ClerkInvitationService.new
      allow(ClerkInvitationService).to receive(:new).and_return(real)
      revocation = request!("sessions", login.id, user: login)
      clear_enqueued_jobs
      # Each piece arrives inside the socket read timeout; the whole never does.
      stub_request(:get, "https://api.clerk.com/v1/sessions")
        .with(query: { user_id: "user_employee_1", status: "active", limit: "100" })
        .to_return do
          100.times { sleep(0.02) }
          { status: 200, body: "[]" }
        end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.perform_now(revocation.id)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(revocation.reload).to have_attributes(confirmed_at: nil, gave_up_at: nil, attempts: 1, leased_until: nil,
        lease_token: nil, last_error: described_class::DEADLINE_ERROR)
      expect(enqueued_jobs.sole.fetch("exception_executions")).to eq("[ClerkInvitationService::DeadlineReached]" => 1)
    ensure
      ENV["CLERK_SECRET_KEY"] = previous
    end

    it "stops a pass at its deadline, inside the lease, and reschedules it to carry on" do
      expect(described_class::PASS_DEADLINE).to be < EmployeeAppClerkRevocation::ATTEMPT_LEASE
      previous = ENV["CLERK_SECRET_KEY"]
      ENV["CLERK_SECRET_KEY"] = "sk_test_synthetic"
      allow(ClerkInvitationService).to receive(:new).and_call_original
      real = ClerkInvitationService.new
      allow(ClerkInvitationService).to receive(:new).and_return(real)
      revocation = request!("sessions", login.id, user: login)
      listing = stub_request(:get, "https://api.clerk.com/v1/sessions")
        .with(query: { user_id: "user_employee_1", status: "active", limit: "100" })
        .to_return({ status: 200, body: [ { id: "sess_one" }, { id: "sess_two" } ].to_json },
          { status: 200, body: [ { id: "sess_two" } ].to_json }, { status: 200, body: "[]" })
      # Clerk is slow enough that the first revocation ends past the deadline.
      first = stub_request(:post, "https://api.clerk.com/v1/sessions/sess_one/revoke").to_return do
        travel(described_class::PASS_DEADLINE + 1.second)
        { status: 200, body: "{}" }
      end
      second = stub_request(:post, "https://api.clerk.com/v1/sessions/sess_two/revoke").to_return(status: 200, body: "{}")

      described_class.perform_now(revocation.id)
      expect(second).not_to have_been_requested
      expect(revocation.reload).to have_attributes(confirmed_at: nil, gave_up_at: nil, attempts: 1, leased_until: nil,
        lease_token: nil, last_error: described_class::DEADLINE_ERROR)
      rescheduled = enqueued_jobs.sole
      expect(rescheduled).to include("job_class" => described_class.name, "arguments" => [ revocation.id ])
      expect(rescheduled.fetch("exception_executions")).to eq("[ClerkInvitationService::DeadlineReached]" => 1)

      # The rescheduled pass picks up what is still active.
      travel_back
      described_class.perform_now(revocation.id)
      expect(revocation.reload).to have_attributes(outcome: "sessions_revoked", last_error: nil, attempts: 2)
      expect(revocation.confirmed_at).to be_present
      expect([ first, second ]).to all(have_been_requested.once)
      expect(listing).to have_been_requested.times(3)
    ensure
      travel_back
      ENV["CLERK_SECRET_KEY"] = previous
    end
  end

  describe RetryEmployeeAppClerkRevocationsJob do
    include ActiveJob::TestHelper
    include ActiveSupport::Testing::TimeHelpers

    let(:organization) { create(:organization) }
    let(:company) { create(:company, organization: organization) }
    let(:admin) { create(:user, company: company, organization: organization, role: :org_admin) }

    def request!(target, at:)
      TenantScope.as_system(reason: "spec") do
        EmployeeAppClerkRevocation.request!(kind: "sessions", target: target, organization: organization, company: company,
          source: EmployeeAppClerkRevocation::SOURCE_DEMO_STOP, requested_by: admin, now: at)
      end
    end

    it "re-enqueues pending revocations whose job never ran or was lost, and leaves live and finished ones" do
      now = Time.current
      never_queued = request!("101", at: now - 10.minutes)
      just_requested = request!("102", at: now - 1.minute)
      lost = request!("103", at: now - 1.day)
      lost.update_columns(enqueued_at: now - 1.day, updated_at: now - 7.hours)
      live = request!("104", at: now - 1.hour)
      live.update_columns(enqueued_at: now - 1.hour, submitted_at: now - 1.hour, updated_at: now - 20.minutes)
      done = request!("105", at: now - 1.day)
      done.update_columns(confirmed_at: now - 1.hour, updated_at: now - 1.day)

      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now(now: now) }).to eq(2)
      expect(RevokeEmployeeAppClerkJob).to have_been_enqueued.with(never_queued.id)
      expect(RevokeEmployeeAppClerkJob).to have_been_enqueued.with(lost.id)
      [ just_requested, live, done ].each { |row| expect(RevokeEmployeeAppClerkJob).not_to have_been_enqueued.with(row.id) }
      expect(never_queued.reload.enqueued_at).to be_within(1.second).of(now)
      expect(never_queued.submitted_at).to be_present

      # Once queued, the next sweep leaves them alone.
      clear_enqueued_jobs
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now(now: now + 1.minute) }).to eq(0)
    end

    it "leaves a row unqueued when its enqueue fails, so the next sweep tries again" do
      row = request!("201", at: 10.minutes.ago)
      allow(RevokeEmployeeAppClerkJob.queue_adapter).to receive(:enqueue).and_raise(ActiveJob::EnqueueError)
      expect(TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ row.id ]) }).to eq([])
      expect(row.reload).to have_attributes(enqueued_at: nil, job_id: nil)
    end

    it "lets exactly one of a sweep and a repeat stop queue a row both read as unqueued" do
      row = request!("301", at: 10.minutes.ago)
      raced = false
      allow(RevokeEmployeeAppClerkJob).to receive(:new).and_wrap_original do |original, *args|
        unless raced
          raced = true
          # The repeat stop reads and claims the row after the sweep read it.
          expect(EmployeeAppClerkRevocation.enqueue!([ row.id ])).to eq([ row.id ])
        end
        original.call(*args)
      end

      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now }).to eq(0)
      expect(RevokeEmployeeAppClerkJob).to have_been_enqueued.with(row.id).exactly(:once)
      expect(row.reload.job_id).to eq(enqueued_jobs.sole.fetch("job_id"))
    end

    it "re-queues a row whose claim committed but whose job never reached the queue" do
      row = request!("501", at: 10.minutes.ago)
      now = Time.current
      # The process dies between the claim and the enqueue.
      allow(RevokeEmployeeAppClerkJob.queue_adapter).to receive(:enqueue).and_raise(Interrupt)
      expect { TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ row.id ], now: now) } }
        .to raise_error(Interrupt)
      allow(RevokeEmployeeAppClerkJob.queue_adapter).to receive(:enqueue).and_call_original
      stranded = row.reload.job_id
      expect(row).to have_attributes(enqueued_at: be_present, submitted_at: nil)
      expect(stranded).to be_present
      expect(RevokeEmployeeAppClerkJob).not_to have_been_enqueued

      # A repeat stop leaves a claimed row alone, and the sweep gives the
      # claim a few minutes to be confirmed ...
      expect(TenantScope.as_system(reason: "spec") { EmployeeAppClerkRevocation.enqueue!([ row.id ], now: now + 1.minute) }).to eq([])
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now(now: now + 2.minutes) }).to eq(0)

      # ... then the short sweep re-queues it, and it stays queued.
      sweep_at = now + EmployeeAppClerkRevocation::UNSUBMITTED_AFTER + 1.minute
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now(now: sweep_at) }).to eq(1)
      expect(RevokeEmployeeAppClerkJob).to have_been_enqueued.with(row.id).exactly(:once)
      expect(row.reload.job_id).to eq(enqueued_jobs.sole.fetch("job_id"))
      expect(row.job_id).not_to eq(stranded)
      expect(row.submitted_at).to be_present
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now(now: sweep_at + 15.minutes) }).to eq(0)
    end

    it "lets exactly one of two sweeps re-queue a row both read as unconfirmed" do
      row = request!("601", at: 1.hour.ago)
      row.update_columns(job_id: "lost-before-submit", enqueued_at: 1.hour.ago, submitted_at: nil)
      raced = false
      allow(RevokeEmployeeAppClerkJob).to receive(:new).and_wrap_original do |original, *args|
        unless raced
          raced = true
          # The other sweep reads and claims the row after this one read it.
          expect(described_class.perform_now).to eq(1)
        end
        original.call(*args)
      end

      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now }).to eq(0)
      expect(RevokeEmployeeAppClerkJob).to have_been_enqueued.with(row.id).exactly(:once)
      expect(row.reload.job_id).to eq(enqueued_jobs.sole.fetch("job_id"))
    end

    it "doesn't replace the job of a row whose attempt is in progress" do
      row = request!("401", at: 1.day.ago)
      row.update_columns(enqueued_at: 1.day.ago, updated_at: 7.hours.ago, leased_until: 5.minutes.from_now)
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now }).to eq(0)
      row.update_columns(leased_until: 1.minute.ago)
      expect(TenantScope.as_system(reason: "spec") { described_class.perform_now }).to eq(1)
    end

    it "runs on a schedule" do
      schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "retry_employee_app_clerk_revocations")
      expect(schedule).to include("class" => described_class.name)
    end
  end
end
