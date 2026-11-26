# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

# Staff web and the worker run the RLS guard in log mode, so they can't use
# their own guard to open a demo under the early-access waiver. They follow
# the employee service's signed answer instead; the employee service, and
# every employee request, still needs its own guard.
RSpec.describe "Demo employee app gate on staff web and the worker", type: :request do
  include EmployeeLinkHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:enforcement) { EmployeeAppSwitch::Enforcement }
  let(:attestation) { EmployeeAppSwitch::ServiceAttestation }
  let(:secret) { "d" * 48 }
  let(:base) { "https://employees-api.example.test" }
  let(:organization) { create(:organization) }
  let(:demo) { create_demo_company(organization: organization, subdomain_slug: "harborfinch") }
  let(:live) { create(:company, organization: organization, name: "Example Grill") }
  let(:owner) { create(:user, company: live, organization: organization, role: :super_admin, clerk_id: "user_gate_owner") }
  let(:staff) { create(:user, company: demo, organization: organization, role: :admin, clerk_id: "user_gate_staff") }
  let(:employee) do
    create(:employee, company: demo, first_name: "Sample", last_name: "Worker", email: "worker@demo-mail.example",
      date_of_birth: Date.new(1991, 1, 2))
  end
  let(:shadow) { { phase: "shadow", enforced: false, kill_switch_bypass: false, enforced_tables: 0, protected_tables: 1 } }
  let(:guard_mode) { "raise" }
  let(:clock_offset) { [ 0.0 ] }
  let(:subdomain) { false }
  let(:demo_origin) { "https://harborfinch.#{TenantSubdomainRegistry::ROOT_DOMAIN}" }

  around do |example|
    env = { attestation::SECRET_ENV => secret, "EMPLOYEE_API_URL" => base, "APP_PROCESS_ROLE" => nil,
            "PORTAL_EMAIL_NOTIFICATIONS_ENABLED" => "true", "PORTAL_EMAIL_TRANSPORT" => "capture",
            "RESEND_FROM_EMAIL" => "payroll@example.test", DemoOutbound::ENV_KEY => "worker@demo-mail.example" }
    saved = env.keys.index_with { |key| ENV[key] }
    env.each { |key, value| ENV[key] = value }
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  before do
    allow(enforcement).to receive(:database_state).and_return(shadow)
    # Staff web and the worker: guard in log mode, no restricted role.
    allow(enforcement).to receive(:current_process_guarded?).and_return(false)
    allow(attestation).to receive(:process_database_facts).and_return([ true, false ])
    allow(Process).to receive(:clock_gettime).and_wrap_original do |original, *args|
      args == [ Process::CLOCK_MONOTONIC ] ? original.call(*args) + clock_offset.first : original.call(*args)
    end
    stub_employee_service!
    enable_employee_app!(demo, subdomain: subdomain)
    PortalNotifications::Transport.clear_captured!
  end

  # The employee service's live answer, signed for the nonce Payroll sent.
  def stub_employee_service!(mode: guard_mode, signing_secret: secret)
    sign_env = { attestation::SECRET_ENV => signing_secret, "APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB,
                 "RLS_CONTEXT_GUARD_MODE" => mode }
    stub_request(:get, "#{base}/health/dependencies").to_return do |request|
      nonce = request.headers[attestation::NONCE_HEADER.split("-").map(&:capitalize).join("-")]
      signed = attestation.sign(nonce: nonce, dependencies_healthy: true, env: sign_env,
        readiness: -> { instance_double(ProductionReadiness, employee_service_checks: []) })
      { status: 200, body: { status: "ok", attestation: signed }.to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  def open_window!(expires_on: PayrollBusinessClock.today + 3)
    EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: [ demo.id ], expires_on: expires_on,
      reason: "Owner approved demo test", set_by: owner)
  end

  def headers(actor = staff)
    bearer(actor.clerk_id).merge("X-Company-Id" => demo.id.to_s)
  end

  def rollout_path
    "/api/v1/admin/employee_app_rollout/#{demo.id}"
  end

  def app_open?
    CompanyFeatures.for(demo).employee_portal_enabled?
  end

  def later!(seconds)
    clock_offset[0] += seconds
  end

  def without_attestation!
    ENV[attestation::SECRET_ENV] = nil
    enforcement.reset_cache!
  end

  def counters(link)
    link.reload.slice(:status, :failed_activation_attempts, :activation_locked_until, :invite_generation, :user_id,
      :invite_code_digest)
  end

  it "opens the rollout, invites and resends for a demo under early access once the employee service attests" do
    open_window!

    get rollout_path, headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data")).to include("enabled" => true)

    post "#{rollout_path}/invite", headers: headers, params: { employee_ids: [ employee.id ], delivery: "code" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data").sole).to include("id" => employee.id, "print" => include("code" => be_present))

    link = employee.employee_account_links.sole
    post "/api/v1/admin/employees/#{employee.id}/employee_app/resend", headers: headers,
      params: { access_id: link.id, delivery: "code" }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(link.reload.invite_generation).to eq(2)

    # The switch page's "open today" reads the same gate.
    expect(EmployeeAppSwitch.effective_values(demo)).to include(EmployeeAppSwitch::MASTER => true)
    # One signed answer serves every read until the cache runs out.
    expect(a_request(:get, "#{base}/health/dependencies")).to have_been_made.once
    # Employee requests on this process still need its own guard.
    expect(enforcement.demo_request_allowed?(demo)).to be(false)
  end

  it "lets the service objects invite and resend on the same terms" do
    open_window!
    issued = invite!(employee, actor: staff, delivery: "code")
    expect(issued.code).to be_present
    resent = as_staff_in(demo) { EmployeeLinks::Resend.call(link: issued.link, actor: staff, delivery: "code") }
    expect(resent.link.reload.invite_generation).to eq(2)
  end

  it "stays closed without an in-effect window naming the demo" do
    expect(app_open?).to be(false)
    expect { invite!(employee, actor: staff, delivery: "code") }.to raise_error(EmployeeLinks::Error, /isn't turned on/)

    open_window!
    travel_to((PayrollBusinessClock.today + 4).in_time_zone(PayrollBusinessClock::TIME_ZONE).change(hour: 9)) do
      expect(app_open?).to be(false)
      expect(EmployeeAppSwitch.effective_values(demo)).to include(EmployeeAppSwitch::MASTER => false)
    end
  end

  context "without a valid signed answer" do
    before { open_window! }

    it "stays closed when the attestation is missing" do
      ENV[attestation::SECRET_ENV] = nil
      expect(app_open?).to be(false)
      expect { invite!(employee, actor: staff, delivery: "code") }.to raise_error(EmployeeLinks::Error, /isn't turned on/)
    end

    it "stays closed when the answer is signed with another secret, unsigned or unreachable" do
      stub_employee_service!(signing_secret: "x" * 48)
      expect(app_open?).to be(false)

      later!(enforcement::ATTESTATION_MISS_CACHE_SECONDS + 1)
      stub_request(:get, "#{base}/health/dependencies").to_return(status: 200, body: { status: "ok" }.to_json)
      expect(app_open?).to be(false)

      later!(enforcement::ATTESTATION_MISS_CACHE_SECONDS + 1)
      stub_request(:get, "#{base}/health/dependencies").to_timeout
      expect(app_open?).to be(false)
    end

    it "stays closed while the employee service's guard isn't in raise mode" do
      stub_employee_service!(mode: "log")
      expect(app_open?).to be(false)
    end

    it "closes once the cached answer goes stale and the next one doesn't verify" do
      expect(app_open?).to be(true)

      stub_request(:get, "#{base}/health/dependencies").to_return(status: 503, body: "")
      later!(enforcement::ATTESTATION_CACHE_SECONDS - 5)
      expect(app_open?).to be(true)
      later!(10)
      expect(app_open?).to be(false)
    end
  end

  it "never takes the attestation path on the employee service itself" do
    open_window!
    employee_env = ENV.to_h.merge("APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB)
    expect(enforcement.demo_reader_allowed?(demo, env: employee_env)).to be(false)
    expect(a_request(:get, "#{base}/health/dependencies")).not_to have_been_made

    allow(enforcement).to receive(:current_process_guarded?).and_return(true)
    expect(enforcement.demo_reader_allowed?(demo, env: employee_env)).to be(true)
  end

  it "leaves real companies and verified enforcement as they were" do
    enable_employee_app!(live)
    ENV[attestation::SECRET_ENV] = nil
    expect(CompanyFeatures.for(live).employee_portal_enabled?).to be(true)

    allow(enforcement).to receive(:database_state).and_return(shadow.merge(phase: "enforced", enforced: true, enforced_tables: 1))
    enforcement.reset_cache!
    expect(app_open?).to be(true)
  end

  describe "employee sign-up on staff web" do
    let(:issued) { invite!(employee, actor: staff, delivery: "code") }
    let(:claimant) do
      create(:user, role: :portal_employee, company: demo, organization: organization, clerk_id: "user_gate_claimant",
        email: "worker@demo-mail.example", name: "Sample Worker", invitation_status: "accepted")
    end

    before { open_window! }

    def claim!(**overrides)
      post "/api/v1/employee/links/claim",
        params: activation_params(employee, code: issued.code).except(:email).merge(overrides).to_json,
        headers: bearer(claimant.clerk_id).merge("CONTENT_TYPE" => "application/json")
    end

    it "refuses activation alike for a match and a miss, before any attempt is counted" do
      before_state = counters(issued.link)

      post_activation(activation_params(employee, code: issued.code))
      matched = [ response.status, response.parsed_body ]
      post_activation(activation_params(employee, code: issued.code, ssn_last4: "0000"))
      missed = [ response.status, response.parsed_body ]

      expect(matched).to eq(missed)
      expect(matched.first).to eq(422)
      expect(counters(issued.link)).to eq(before_state)
      expect(link_audits(issued.link, "activation_failed")).to be_empty
    end

    it "refuses a claim alike for a match and a miss, leaving the invite as it was" do
      before_state = counters(issued.link)

      claim!
      matched = [ response.status, response.parsed_body ]
      claim!(ssn_last4: "0000")
      expect([ response.status, response.parsed_body ]).to eq(matched)
      expect(matched.first).to eq(404)
      expect(counters(issued.link)).to eq(before_state)
      expect(claimant.reload.employee_account_links).to be_empty
    end

    it "refuses a staff-origin claim alike for a match and a miss once RLS enforcement is verified, counting nothing" do
      allow(enforcement).to receive(:database_state).and_return(shadow.merge(phase: "enforced", enforced: true, enforced_tables: 1))
      enforcement.reset_cache!
      before_state = counters(issued.link)

      claim!
      matched = [ response.status, response.parsed_body ]
      claim!(ssn_last4: "0000")
      expect([ response.status, response.parsed_body ]).to eq(matched)
      expect(matched.first).to eq(404)
      expect(counters(issued.link)).to eq(before_state)
      expect(link_audits(issued.link, "activation_failed")).to be_empty
    end

    it "refuses a claim whose browser Origin isn't the demo's own, alike for a match and a miss, counting nothing" do
      allow(enforcement).to receive(:database_state).and_return(shadow.merge(phase: "enforced", enforced: true, enforced_tables: 1))
      enforcement.reset_cache!
      before_state = counters(issued.link)
      elsewhere = { "Origin" => EmployeeLinkHelpers::PAYROLL_ORIGIN }

      post "/api/v1/employee/links/claim", params: activation_params(employee, code: issued.code).except(:email).to_json,
        headers: bearer(claimant.clerk_id).merge("CONTENT_TYPE" => "application/json", **elsewhere)
      matched = [ response.status, response.parsed_body ]
      post "/api/v1/employee/links/claim", params: activation_params(employee, code: issued.code, ssn_last4: "0000").except(:email).to_json,
        headers: bearer(claimant.clerk_id).merge("CONTENT_TYPE" => "application/json", **elsewhere)
      expect([ response.status, response.parsed_body ]).to eq(matched)
      expect(counters(issued.link)).to eq(before_state)
    end

    it "lets the guarded employee service count a miss as before" do
      allow(enforcement).to receive(:current_process_guarded?).and_return(true)
      post_activation(activation_params(employee, code: issued.code, ssn_last4: "0000"))
      expect(response).to have_http_status(:unprocessable_content)
      expect(issued.link.reload.failed_activation_attempts).to eq(1)
    end
  end

  describe "employee data on staff web" do
    let(:subdomain) { true }
    let(:worker) do
      create(:user, role: :portal_employee, company: demo, organization: organization, clerk_id: "user_gate_worker",
        email: "worker@demo-mail.example", invitation_status: "accepted")
    end
    let!(:link) { EmployeeAccountLink.create!(user: worker, company: demo, employee: employee, status: "active") }

    before { open_window! }

    def employee_get(path)
      get path, headers: bearer(worker.clerk_id, azp: demo_origin).merge("X-Employee-Link-Id" => link.id.to_s, "Origin" => demo_origin)
    end

    it "still denies the portal and its PDFs; a guarded process serves them" do
      expect(app_open?).to be(true)
      [ "/api/v1/employee/context", "/api/v1/employee/statements", "/api/v1/employee/statements/1/pdf",
        "/api/v1/employee/tax_forms/1/pdf" ].each do |path|
        employee_get(path)
        expect(response).to have_http_status(:not_found), path
      end
      get "/api/v1/employee/links", headers: bearer(worker.clerk_id, azp: demo_origin)
      expect(response.parsed_body["links"]).to eq([])

      allow(enforcement).to receive(:current_process_guarded?).and_return(true)
      employee_get("/api/v1/employee/context")
      expect(response).to have_http_status(:ok), response.body
    end
  end

  describe "employee mail" do
    before { open_window! }

    it "sends an email invite from staff web with the signed answer, and refuses it without" do
      expect(invite!(employee, actor: staff).email_status).to eq(:captured)
      expect(PortalNotifications::Transport.captured.flat_map { |mail| Array(mail[:to]) }).to include("worker@demo-mail.example")

      other = create(:employee, company: demo, email: "other@demo-mail.example", date_of_birth: Date.new(1990, 5, 6))
      without_attestation!
      expect { invite!(other, actor: staff) }.to raise_error(EmployeeLinks::Error, /isn't turned on/)
    end

    it "sends a worker's activation notice with the signed answer, and suppresses it without" do
      link = invite!(employee, actor: staff, delivery: "code").link
      notice = -> { link.update_columns(activation_notice_email: "worker@demo-mail.example", activation_notice_status: "pending") }

      notice.call
      expect(SendEmployeeActivationNoticeJob.perform_now(link.id)).to eq(:captured)
      expect(link.reload.activation_notice_status).to eq("sent")

      notice.call
      without_attestation!
      expect(SendEmployeeActivationNoticeJob.perform_now(link.id)).to eq(:skipped)
      expect(link.reload.activation_notice_status).to eq("skipped")
    end
  end

  describe "the attestation path" do
    before { open_window! }

    it "is never taken by the employee service, an unknown role, or a process without the URL" do
      allow(enforcement).to receive(:employee_service_attested?).and_call_original
      env = ENV.to_h
      [ env.merge("APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB), env.merge("APP_PROCESS_ROLE" => "worker"),
        env.merge("EMPLOYEE_API_URL" => nil) ].each do |refused|
        expect(enforcement.demo_reader_allowed?(demo, env: refused)).to be(false), refused.slice("APP_PROCESS_ROLE").inspect
      end
      expect(enforcement).not_to have_received(:employee_service_attested?)
      expect(a_request(:get, "#{base}/health/dependencies")).not_to have_been_made

      [ env.except("APP_PROCESS_ROLE"), env.merge("APP_PROCESS_ROLE" => ProcessRole::PAYROLL_WEB) ].each do |allowed|
        enforcement.reset_cache!
        expect(enforcement.demo_reader_allowed?(demo, env: allowed)).to be(true)
      end
      expect(enforcement).to have_received(:employee_service_attested?).twice
    end

    it "never retries the ask, and gives up at the deadline however slowly the answer comes" do
      allow(Net::HTTP).to receive(:start).and_call_original
      expect(app_open?).to be(true)
      expect(Net::HTTP).to have_received(:start).with(anything, anything, hash_including(max_retries: 0))

      enforcement.reset_cache!
      stub_const("#{enforcement}::ATTESTATION_DEADLINE_SECONDS", 0.3)
      stub_request(:get, "#{base}/health/dependencies").to_return { sleep 2; { status: 200, body: "{}" } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(app_open?).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
    end

    it "waits only briefly for another thread's refresh, then reads the app as off" do
      enforcement::ATTESTATION_LOCK.lock
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(Thread.new { enforcement.employee_service_attested? }.value).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        .to be_between(enforcement::ATTESTATION_WAIT_SECONDS, enforcement::ATTESTATION_WAIT_SECONDS + 1)
      expect(a_request(:get, "#{base}/health/dependencies")).not_to have_been_made
    ensure
      enforcement::ATTESTATION_LOCK.unlock if enforcement::ATTESTATION_LOCK.owned?
    end

    it "reads only the cached answer while an invitation holds the issuance lock" do
      expect(EmployeeLinks).to receive(:lock_for_issuance!).and_wrap_original do |original, *args|
        original.call(*args)
        # The answer expires after the lock is taken: no ask from inside it.
        later!(enforcement::ATTESTATION_CACHE_SECONDS + 1)
      end
      expect { invite!(employee, actor: staff, delivery: "code") }.to raise_error(EmployeeLinks::Error, /isn't turned on/)
      expect(a_request(:get, "#{base}/health/dependencies")).to have_been_made.once
      expect(EmployeeAccountLink.where(employee_id: employee.id)).to be_empty

      # Once the transaction ends, the next read asks again.
      expect(enforcement.cached_attestation_only?).to be(false)
      expect(app_open?).to be(true)
      expect(a_request(:get, "#{base}/health/dependencies")).to have_been_made.twice
    end

    it "makes one request when several threads find the cache empty" do
      stub_request(:get, "#{base}/health/dependencies").to_return do |request|
        sleep 0.2
        nonce = request.headers[attestation::NONCE_HEADER.split("-").map(&:capitalize).join("-")]
        signed = attestation.sign(nonce: nonce, dependencies_healthy: true,
          env: { attestation::SECRET_ENV => secret, "APP_PROCESS_ROLE" => ProcessRole::EMPLOYEE_WEB, "RLS_CONTEXT_GUARD_MODE" => "raise" },
          readiness: -> { instance_double(ProductionReadiness, employee_service_checks: []) })
        { status: 200, body: { status: "ok", attestation: signed }.to_json }
      end

      answers = Array.new(4) { Thread.new { enforcement.employee_service_attested? } }.map(&:value)
      expect(answers).to eq([ true ] * 4)
      expect(a_request(:get, "#{base}/health/dependencies")).to have_been_made.once
    end

    it "asks with a short timeout" do
      allow(EmployeeAppSwitch::Readiness).to receive(:ping_employee_service).and_call_original
      app_open?
      expect(EmployeeAppSwitch::Readiness).to have_received(:ping_employee_service)
        .with(anything, open_timeout: enforcement::ATTESTATION_OPEN_TIMEOUT, read_timeout: enforcement::ATTESTATION_READ_TIMEOUT)
      expect(enforcement::ATTESTATION_OPEN_TIMEOUT + enforcement::ATTESTATION_READ_TIMEOUT).to be <= 3
    end

    it "warms the answer before an invitation takes its locks" do
      allow(enforcement).to receive(:warm_attestation!).and_call_original
      expect(EmployeeLinks).to receive(:lock_for_issuance!).and_wrap_original do |original, *args|
        expect(enforcement.fresh_attestation&.first).to be(true)
        original.call(*args)
      end
      invite!(employee, actor: staff, delivery: "code")
      expect(enforcement).to have_received(:warm_attestation!).with(demo)
    end
  end
end
