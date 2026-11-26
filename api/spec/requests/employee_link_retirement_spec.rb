# frozen_string_literal: true

require "rails_helper"

# M4-2 part B: termination and deactivation from both status services, staff
# revoke, the daily expiry job, and rehire reactivation. Staff and employee
# requests use real token verification under the RLS guard in raise mode.
RSpec.describe "Employee link retirement", type: :request do
  include EmployeeLinkHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Example Diner") }
  let!(:staff) { create(:user, role: :admin, company: company, clerk_id: "user_staff") }
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", email: "riley.own@example.net",
      date_of_birth: Date.new(1990, 4, 12), hire_date: Date.new(2024, 1, 1))
  end
  let(:worker) do
    create(:user, role: :portal_employee, company: company, name: "Riley Santos", email: "riley.own@example.net",
      clerk_id: "user_riley", invitation_status: "accepted")
  end
  let(:link) do
    EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active", activated_at: 1.day.ago)
  end
  let(:staff_headers) { bearer("user_staff").merge("X-Company-Id" => company.id.to_s) }

  before { enable_employee_app!(company) }

  def context_status(user_subject = "user_riley", for_link: link)
    get "/api/v1/employee/context", headers: bearer(user_subject).merge("X-Employee-Link-Id" => for_link.id.to_s)
    response.status
  end

  def terminate!(on:)
    post "/api/v1/admin/employees/#{employee.id}/terminate", headers: staff_headers, as: :json,
      params: { termination: { effective_date: on.iso8601, reason_category: "voluntary" } }
    expect(response).to have_http_status(:ok)
  end

  def deactivate!
    post "/api/v1/admin/employees/#{employee.id}/deactivate", headers: staff_headers, as: :json,
      params: { deactivation: { effective_date: (PayrollBusinessClock.today - 1).iso8601, reason_category: "other" } }
    expect(response).to have_http_status(:ok)
  end

  describe "termination" do
    it "makes the link former with termination date + 2 years by default, keeps read-only access and the staff audit" do
      expect(context_status).to eq(200)
      termination = PayrollBusinessClock.today - 10

      terminate!(on: termination)

      expect(link.reload).to have_attributes(status: "former")
      expect(link.former_access_until).to be_within(1.second).of((termination + 2.years).in_time_zone("Pacific/Guam").end_of_day)
      expect(link_audits(link, "made_former").sole).to have_attributes(user_id: staff.id, company_id: company.id)
      expect(AuditLog.where(action: "employees#terminate", record_id: employee.id).count).to eq(1)
      expect(worker.reload).to be_active
      expect(context_status).to eq(200)
    end

    it "uses the company's own former_access_years" do
      profile = company.client_operating_profiles.sole
      profile.update_columns(options: profile.options.deep_merge("employee_portal" => { "former_access_years" => 5 }))
      termination = PayrollBusinessClock.today - 1
      link

      terminate!(on: termination)

      expect(link.reload.former_access_until.to_date).to eq(termination + 5.years)
    end

    it "closes the login and signs it out at once when the window has already passed" do
      link
      clear_enqueued_jobs

      terminate!(on: Date.new(2024, 2, 1))

      expect(link.reload).to have_attributes(status: "former")
      expect(worker.reload).not_to be_active
      expect(RevokeEmployeeSessionsJob).to have_been_enqueued.with(worker.id, kind_of(String))
      expect(AuditLog.where(action: "authentication#employee_login_deactivated", record_id: worker.id).sole)
        .to have_attributes(company_id: company.id)
      expect(context_status).to eq(404)
    end

    it "revokes an invite nobody finished, closing its pending login" do
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "pending@example.net"))
      pending_user = invite.link.reload.user

      terminate!(on: PayrollBusinessClock.today)

      expect(invite.link.reload).to have_attributes(status: "revoked", revoked_reason: "employment_ended", revoked_by_id: staff.id,
        invite_code_digest: nil)
      expect(pending_user.reload).to have_attributes(active: false, invite_nonce_digest: nil)
      expect(clerk).to have_received(:revoke_invitation).with("inv_1")
    end

    it "moves the old record's link to former in a W-2/1099 classification transition" do
      super_admin = create(:user, role: :super_admin, company: company, clerk_id: "user_super")
      employee = create(:employee, :contractor, company: company, first_name: "Riley", last_name: "Santos",
        ssn_encrypted: "123-45-6789", hire_date: Date.new(2024, 1, 1))
      link = EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active")

      post "/api/v1/admin/employees/#{employee.id}/transition_tax_classification", as: :json,
        headers: bearer("user_super").merge("X-Company-Id" => company.id.to_s),
        params: { transition: { employment_type: "hourly", effective_date: PayrollBusinessClock.today.iso8601,
          reason: "Begins W-2 employment", pay_rate: 15, pay_frequency: "biweekly", filing_status: "single",
          ssn: employee.ssn_encrypted, ssn_confirmation: employee.ssn_encrypted } }

      expect(response).to have_http_status(:created)
      expect(link.reload).to have_attributes(status: "former")
      expect(link.former_access_until.to_date).to eq(employee.reload.termination_date + 2.years)
      expect(link_audits(link, "made_former").sole.user_id).to eq(super_admin.id)
    end
  end

  describe "deactivation without a termination date" do
    it "revokes with a reason, starts no former window, deactivates the last login and signs it out" do
      link
      clear_enqueued_jobs

      deactivate!

      expect(link.reload).to have_attributes(status: "revoked", revoked_reason: "worker_deactivated", former_access_until: nil,
        revoked_by_id: staff.id)
      expect(worker.reload).not_to be_active
      expect(RevokeEmployeeSessionsJob).to have_been_enqueued.with(worker.id, kind_of(String))
      expect(context_status).to eq(404)
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
    end

    it "keeps an employee-only login open while it may still reach another company" do
      other_company = create(:company, organization: company.organization)
      enable_employee_app!(other_company)
      other_link = EmployeeAccountLink.create!(user: worker, company: other_company, status: "active",
        employee: create(:employee, company: other_company))
      link

      deactivate!

      expect(link.reload).to be_revoked
      expect(worker.reload).to be_active
      expect(context_status(for_link: other_link)).to eq(200)
    end

    it "never deactivates a staff or client login, only its link" do
      client = create(:user, role: :client, company: company, clerk_id: "user_client")
      client_link = EmployeeAccountLink.create!(user: client, company: company, employee: employee, status: "active")

      deactivate!

      expect(client_link.reload).to be_revoked
      expect(client.reload).to be_active
      expect(context_status("user_client", for_link: client_link)).to eq(404)
    end
  end

  describe "staff revoke" do
    it "records who, why and when, ends access on the next request and signs the person out" do
      expect(context_status).to eq(200)
      clear_enqueued_jobs

      as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Lost phone, reported by manager") }

      expect(link.reload).to have_attributes(status: "revoked", revoked_by_id: staff.id, revoked_reason: "Lost phone, reported by manager")
      expect(link.revoked_at).to be_present
      expect(link_audits(link, "revoked").sole).to have_attributes(user_id: staff.id, event_category: "security")
      expect(context_status).to eq(404)

      allow(clerk).to receive(:revoke_user_sessions).and_return(success: true, revoked: 2)
      perform_enqueued_jobs(only: RevokeEmployeeSessionsJob)
      expect(clerk).to have_received(:revoke_user_sessions)
        .with("user_riley", created_before: worker.reload.deactivated_at + EmployeeLinks::SessionFence::SESSION_SKEW_ALLOWANCE)
    end

    it "requires staff and a reason" do
      expect { as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: " ") } }
        .to raise_error(EmployeeLinks::Error, /reason/)
      expect { as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: worker, reason: "x") } }
        .to raise_error(EmployeeLinks::Forbidden)
      expect(link.reload).to be_active
    end
  end

  describe ExpireEmployeeLinksJob do
    it "revokes stale invites and ended former access, and closes logins left with nothing" do
      invite = invite!(create(:employee, company: company, email: "late@example.net", date_of_birth: Date.new(1985, 5, 5)),
        actor: staff)
      post_activation(activation_params(invite.link.employee, token: invite.token, email: "late@example.net"))
      pending_user = invite.link.reload.user
      link.update_columns(status: "former", former_access_until: 1.day.from_now)
      leftover = create(:user, role: :portal_employee, company: company, clerk_id: "user_left", invitation_status: "accepted")
      EmployeeAccountLink.create!(user: leftover, company: company, employee: create(:employee, company: company),
        status: "revoked", revoked_at: 1.day.ago)

      travel_to(15.days.from_now) { described_class.perform_now }

      expect(invite.link.reload).to have_attributes(status: "revoked", revoked_reason: "invite_expired", invite_token_digest: nil)
      expect(pending_user.reload).not_to be_active
      expect(link.reload).to have_attributes(status: "revoked", revoked_reason: "former_access_ended")
      expect(worker.reload).not_to be_active
      expect(leftover.reload).not_to be_active
      expect(link_audits(link, "revoked").sole).to have_attributes(actor_type: "system_job", user_id: nil)
      expect(RevokeEmployeeSessionsJob).to have_been_enqueued.with(worker.id, kind_of(String))
    end

    it "leaves open invites, current former access and active links alone" do
      invite = invite!(create(:employee, company: company, email: "fresh@example.net"), actor: staff)
      link.update_columns(status: "former", former_access_until: 30.days.from_now)

      described_class.perform_now

      expect(invite.link.reload).to be_invited
      expect(link.reload).to be_former
      expect(worker.reload).to be_active
    end
  end

  describe "rehire of an employee-only person" do
    def reactivate(params, fva: [ 0, -1 ], sid: "sess_user_riley")
      post "/api/v1/employee/links/reactivate", params: params.to_json,
        headers: bearer("user_riley", fva: fva, sid: sid).merge("CONTENT_TYPE" => "application/json")
    end

    before do
      link
      deactivate!
      # Clerk's record of an old session and of the person's sign-in after the closure.
      closed_at = worker.reload.deactivated_at
      clerk_session!("sess_before_closure", user_id: "user_riley", created_at: closed_at - 30.minutes)
      clerk_session!("sess_user_riley", user_id: "user_riley",
        created_at: closed_at + EmployeeLinks::SessionFence::SESSION_SKEW_ALLOWANCE + 1.second)
      travel 20.minutes
      post "/api/v1/admin/employees/#{employee.id}/reactivate", headers: bearer("user_staff").merge("X-Company-Id" => company.id.to_s), as: :json,
        params: { reactivation: { effective_date: PayrollBusinessClock.today.iso8601 } }
    end

    after { travel_back }

    it "routes the new invite to reactivation and binds it to the same login after a fresh sign-in" do
      expect(response).to have_http_status(:ok)
      expect(worker.reload).not_to be_active
      # Its earlier link was revoked, so staff confirm it's the same person (M4-3).
      invite = invite!(employee.reload, actor: staff, confirm_same_person_email: true)
      expect(invite).to have_attributes(path: "reactivate")
      clerk_account!("user_riley", email: "riley.own@example.net")
      expect(invite.link.claim_user_id).to eq(worker.id)

      # A deactivated login can't use any other employee route.
      get "/api/v1/employee/links", headers: bearer("user_riley")
      expect(response).to have_http_status(:not_found)
      post "/api/v1/employee/links/claim", params: activation_params(employee, token: invite.token).to_json,
        headers: bearer("user_riley").merge("CONTENT_TYPE" => "application/json")
      expect(response).to have_http_status(:not_found)

      # A session created before the login closed is refused outright.
      reactivate(activation_params(employee, token: invite.token), sid: "sess_before_closure")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["code"]).to eq("session_predates_reactivation")

      # One created after the closure, but not verified recently, must step up.
      reactivate(activation_params(employee, token: invite.token), fva: [ 15, -1 ])
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("clerk_error", "metadata", "reverification", "level")).to eq("first_factor")

      expect do
        reactivate(activation_params(employee, token: invite.token))
      end.not_to change(User, :count)

      expect(response).to have_http_status(:created)
      expect(worker.reload).to be_active
      expect(invite.link.reload).to have_attributes(status: "active", user_id: worker.id)
      expect(link.reload).to be_revoked
      expect(link_audits(invite.link, "reactivated").sole.user_id).to eq(worker.id)
      expect(AuditLog.where(action: "authentication#employee_login_reactivated", record_id: worker.id).count).to eq(1)
      expect(context_status(for_link: invite.link)).to eq(200)
      expect(context_status).to eq(404)
    end

    it "leaves both the login and the new link inactive when any check fails" do
      invite = invite!(employee.reload, actor: staff, delivery: "code")
      stranger = create(:employee, company: company, date_of_birth: Date.new(1975, 7, 7))
      stranger_invite = invite!(stranger, actor: staff, delivery: "code")

      [
        activation_params(employee, code: invite.code, ssn_last4: "0000"),
        activation_params(employee, code: invite.code, date_of_birth: "1990-04-13"),
        activation_params(employee, code: "ACDEFGHJKM"),
        # The login never had a link to this other employee.
        activation_params(stranger, code: stranger_invite.code)
      ].each do |params|
        reactivate(params)
        expect(response).to have_http_status(:not_found)
      end

      expect(worker.reload).not_to be_active
      expect([ invite.link.reload.status, stranger_invite.link.reload.status ]).to eq(%w[invited invited])
      expect([ invite.link.user_id, stranger_invite.link.user_id ]).to eq([ nil, nil ])
    end

    it "refuses an active login, which claims instead" do
      worker.reload.update!(active: true)
      invite = invite!(employee.reload, actor: staff, delivery: "code")

      reactivate(activation_params(employee, code: invite.code))

      expect(response).to have_http_status(:not_found)
      expect(invite.link.reload).to be_invited
    end
  end

  describe RevokeEmployeeSessionsJob do
    # A fixed, microsecond-exact closure time (what the job's argument
    # carries) and a frozen clock, so nothing depends on the run's timing.
    let(:closed_at) { Time.zone.parse("2026-11-20T02:00:00.123456Z") }

    around { |example| freeze_time { example.run } }

    it "retries until Clerk confirms, and still ends pre-closure sessions of a login that is active again" do
      worker.update!(active: false, deactivated_at: closed_at, deactivation_reason: "last_employee_link_closed")
      cutoffs = []
      outcomes = [ { success: false, error: "timeout" }, { success: true, revoked: 1 } ]
      allow(clerk).to receive(:revoke_user_sessions) do |subject, created_before:|
        cutoffs << [ subject, created_before ]
        outcomes.shift
      end

      expect { described_class.perform_now(worker.id, closed_at.iso8601(6)) }.to have_enqueued_job(described_class)
        .with(worker.id, closed_at.iso8601(6))
      worker.update!(active: true)
      described_class.perform_now(worker.id, closed_at.iso8601(6))

      cutoff = closed_at + EmployeeLinks::SessionFence::SESSION_SKEW_ALLOWANCE
      expect(cutoffs).to eq([ [ "user_riley", cutoff ], [ "user_riley", cutoff ] ])
      expect(outcomes).to be_empty
    end

    it "skips a login that is active again when no closure time was recorded" do
      allow(clerk).to receive(:revoke_user_sessions)
      described_class.perform_now(worker.id)
      expect(clerk).not_to have_received(:revoke_user_sessions)
    end
  end
end
