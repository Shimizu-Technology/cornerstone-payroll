# frozen_string_literal: true

require "rails_helper"

# M4-2 part B review fixes: reactivation only after a last-link closure and
# only with a post-closure session, pre-closure sessions fenced for good,
# lock order and re-checks under lock, the narrow "eligible now" decision,
# reuse of a closed sign-up's address, and printed-code rehires.
RSpec.describe "Employee link retirement hardening", type: :request do
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
    EmployeeAccountLink.create!(user: worker, company: company, employee: employee, status: "active", activated_at: 10.days.ago)
  end

  before { enable_employee_app!(company) }

  def reactivate(params, fva: [ 0, -1 ], sid: "sess_user_riley", path: "/api/v1/employee/links/reactivate")
    post path, params: params.to_json, headers: bearer("user_riley", fva: fva, sid: sid).merge("CONTENT_TYPE" => "application/json")
  end

  # The person's last link closed. Clerk reports one session from before the
  # closure (sess_before_closure) and the current one, from after it.
  def close_last_link!
    link
    as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Seasonal layoff") }
    expect(worker.reload).to have_attributes(active: false, deactivation_reason: "last_employee_link_closed")
    clerk_session!("sess_before_closure", user_id: "user_riley", created_at: worker.deactivated_at - 30.minutes)
    clerk_session!("sess_user_riley", user_id: "user_riley",
      created_at: worker.deactivated_at + EmployeeLinks::SessionFence::SESSION_SKEW_ALLOWANCE + 1.second)
  end

  # Jobs run in a system scope (rls_mode :system); calling a step directly does too.
  def sweep_close(link_id, kind, now)
    job = ExpireEmployeeLinksJob.new
    Current.with_isolated_actor(AuditActor.system_job(job)) do
      TenantScope.as_system(reason: "Spec: expiry sweep step") { job.close(link_id, kind, now) }
    end
  end

  def row_locks
    locks = []
    capture = lambda do |*, payload|
      sql = payload[:sql].to_s
      next unless sql.include?("FOR UPDATE") || sql.include?("FOR NO KEY UPDATE")

      locks << :user if sql.include?('FROM "users"')
      locks << :link if sql.include?('FROM "employee_account_links"')
      locks << :employee if sql.include?('FROM "employees"')
    end
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { yield }
    locks
  end

  describe "rehire reactivation" do
    before { close_last_link! }

    it "doesn't ask Clerk about the session on routes that refuse an inactive login anyway" do
      get "/api/v1/employee/links", headers: bearer("user_riley")
      expect(response).to have_http_status(:not_found)
      get "/api/v1/auth/me", headers: bearer("user_riley")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Account inactive")

      expect(clerk).not_to have_received(:fetch_session)
    end

    it "can't lift an admin's deactivation" do
      invite = invite!(employee, actor: staff, delivery: "code")
      expect(invite).to have_attributes(path: "reactivate")

      post "/api/v1/admin/users/#{worker.id}/deactivate", headers: bearer("user_staff").merge("X-Company-Id" => company.id.to_s)
      expect(worker.reload).to have_attributes(active: false, deactivation_reason: "deactivated")

      reactivate(activation_params(employee, code: invite.code))
      expect(response).to have_http_status(:not_found)
      expect(worker.reload).not_to be_active
      expect(invite.link.reload).to have_attributes(status: "invited", user_id: nil)

      # A new invite can't reach it either, and won't make a second login.
      as_staff_in(company) { EmployeeLinks::Revoke.call(link: invite.link, actor: staff, reason: "Reissue") }
      expect { invite!(employee, actor: staff, delivery: "code") }.to raise_error(EmployeeLinks::Error, /deactivated by an admin/)
    end

    it "refuses a session from before the closure, and keeps refusing it after reactivation" do
      invite = invite!(employee, actor: staff, delivery: "code")

      # A session created before the closure, though it stepped up just now.
      reactivate(activation_params(employee, code: invite.code), fva: [ 0, 0 ], sid: "sess_before_closure")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "Sign in again to continue", "code" => "session_predates_reactivation")
      expect(worker.reload).not_to be_active

      reactivate(activation_params(employee, code: invite.code))
      expect(response).to have_http_status(:created)
      expect(worker.reload).to have_attributes(active: true, deactivation_reason: nil)
      expect(worker.deactivated_at).to be_present

      old_session = bearer("user_riley", sid: "sess_before_closure")
      get "/api/v1/employee/context", headers: old_session.merge("X-Employee-Link-Id" => invite.link.id.to_s)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["code"]).to eq("session_predates_reactivation")
      get "/api/v1/auth/me", headers: old_session
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["code"]).to eq("session_predates_reactivation")

      get "/api/v1/employee/context", headers: bearer("user_riley").merge("X-Employee-Link-Id" => invite.link.id.to_s)
      expect(response).to have_http_status(:ok)
    end

    it "routes a printed-code rehire to the earlier login, so sign-up can't make a second identity" do
      invite = invite!(employee, actor: staff, delivery: "code")
      expect(invite).to have_attributes(path: "reactivate")
      expect(invite.link.claim_user_id).to eq(worker.id)

      expect do
        post_activation(activation_params(employee, code: invite.code, email: "riley.new@example.net"))
      end.not_to change(User, :count)
      expect(response.parsed_body["next"]).to eq("sign_in")
    end

    it "refuses check fields in the query string" do
      invite = invite!(employee, actor: staff, delivery: "code")
      reactivate(activation_params(employee, code: invite.code), path: "/api/v1/employee/links/reactivate?code=ACDEFGHJKM")
      expect(response).to have_http_status(:bad_request)
      expect(worker.reload).not_to be_active
    end
  end

  describe "deciding under lock" do
    it "skips an invite a resend renewed after the sweep read it" do
      invite = invite!(create(:employee, company: company, email: "late@example.net"), actor: staff)
      now = 15.days.from_now
      # The sweep's read saw it expired; a resend renewed it before the lock.
      invite.link.update_columns(invite_expires_at: now + 14.days)

      expect(sweep_close(invite.link.id, :invite, now)).to be(false)
      expect(invite.link.reload).to be_invited
    end

    it "locks the login before the link on revoke, expiry and termination" do
      link
      revoke_locks = row_locks do
        as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Lost phone") }
      end
      expect(revoke_locks.first(2)).to eq(%i[user link])

      other = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", date_of_birth: Date.new(1988, 1, 2))
      other_login = create(:user, role: :portal_employee, company: company, name: "Avery Cruz", email: "avery@example.net",
        clerk_id: "user_avery", invitation_status: "accepted")
      former = EmployeeAccountLink.create!(user: other_login, company: company, employee: other, status: "former",
        activated_at: 1.year.ago, former_at: 1.day.ago, former_access_until: 1.minute.ago)
      expiry_locks = row_locks { expect(sweep_close(former.id, :former, Time.current)).to be(true) }
      expect(expiry_locks.first(2)).to eq(%i[user link])
      expect(former.reload).to be_revoked

      third = create(:employee, company: company, first_name: "Jordan", last_name: "Reyes", hire_date: Date.new(2024, 1, 1))
      third_login = create(:user, role: :portal_employee, company: company, name: "Jordan Reyes", email: "jordan@example.net",
        clerk_id: "user_jordan", invitation_status: "accepted")
      EmployeeAccountLink.create!(user: third_login, company: company, employee: third, status: "active", activated_at: 1.day.ago)
      termination_locks = row_locks do
        post "/api/v1/admin/employees/#{third.id}/terminate", headers: bearer("user_staff").merge("X-Company-Id" => company.id.to_s),
          as: :json, params: { termination: { effective_date: (PayrollBusinessClock.today - 1).iso8601, reason_category: "voluntary" } }
      end
      expect(response).to have_http_status(:ok)
      # (The staff sign-in itself may lock the staff login first.)
      retire_locks = termination_locks.drop(termination_locks.index(:employee))
      expect(retire_locks.index(:user)).to be < retire_locks.index(:link)
    end

    it "counts every eligible link in the sweep, the last one by id included" do
      older = EmployeeAccountLink.create!(user: worker, company: company, status: "revoked", revoked_at: 2.days.ago,
        employee: create(:employee, company: company))
      expect(older.id).to be < link.id

      TenantScope.as_system(reason: "Spec: sweep step") do
        EmployeeLinks::Close.deactivate_if_last!(worker, closed_link: nil, audit_company_id: company.id)
      end

      expect(worker.reload).to be_active
    end
  end

  describe "the narrow eligible-now decision" do
    let(:elsewhere) { create(:company, organization: company.organization, name: "Second Diner") }

    before { link }

    it "ends the login at once when the only other link is former access that already ran out" do
      EmployeeAccountLink.create!(user: worker, company: elsewhere, employee: create(:employee, company: elsewhere),
        status: "former", activated_at: 1.year.ago, former_at: 3.years.ago, former_access_until: 1.day.ago)

      as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Left the company") }

      expect(worker.reload).to have_attributes(active: false, deactivation_reason: "last_employee_link_closed")
    end

    it "keeps the login while former access elsewhere is still running" do
      EmployeeAccountLink.create!(user: worker, company: elsewhere, employee: create(:employee, company: elsewhere),
        status: "former", activated_at: 1.year.ago, former_at: 1.day.ago, former_access_until: 1.year.from_now)

      as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Left the company") }

      expect(worker.reload).to be_active
    end

    it "answers only true or false, and nothing about logins with no link at the session's company" do
      stranger = create(:user, role: :portal_employee, company: elsewhere, email: "stranger@example.net",
        clerk_id: "user_stranger", invitation_status: "accepted")
      EmployeeAccountLink.create!(user: stranger, company: elsewhere, employee: create(:employee, company: elsewhere),
        status: "active", activated_at: 1.day.ago)

      answers = as_staff_in(company) do
        [ EmployeeAccountLink.login_has_eligible_link?(user_id: worker.id, except_link_id: nil),
          EmployeeAccountLink.login_has_eligible_link?(user_id: worker.id, except_link_id: link.id),
          EmployeeAccountLink.login_has_eligible_link?(user_id: stranger.id, except_link_id: nil) ]
      end
      expect(answers).to eq([ true, false, false ])
    end
  end

  describe "an unfinished sign-up's address" do
    it "is reused by the same employee's next invite instead of being stranded" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      pending_user = invite.link.reload.user

      travel_to(15.days.from_now) do
        ExpireEmployeeLinksJob.perform_now
        expect(pending_user.reload).to have_attributes(active: false, deactivation_reason: "pending_sign_up_closed")

        again = invite!(employee.reload, actor: staff)
        expect(again).to have_attributes(path: "sign_up")
        expect(again.link.claim_user_id).to be_nil

        expect do
          post_activation(activation_params(employee, token: again.token, email: "riley.own@example.net"))
        end.not_to change(User, :count)
        expect_sign_up_started
        expect(again.link.reload.user_id).to eq(pending_user.id)
        expect(pending_user.reload).to have_attributes(active: true, deactivation_reason: nil)

        accept_clerk_invitation!("user_riley_new")
        get "/api/v1/auth/me", headers: bearer("user_riley_new")
        expect(response).to have_http_status(:ok)
        expect(again.link.reload).to have_attributes(status: "active", user_id: pending_user.id)
      end
    end

    it "is never reused for a different employee" do
      invite = invite!(employee, actor: staff)
      post_activation(activation_params(employee, token: invite.token, email: "riley.own@example.net"))
      other = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", email: "avery@example.net",
        date_of_birth: Date.new(1988, 1, 2))
      other_invite = nil

      travel_to(15.days.from_now) do
        expect(sweep_close(invite.link.id, :invite, Time.current)).to be(true)
        other_invite = invite!(other, actor: staff)
        post_activation(activation_params(other, token: other_invite.token, email: "riley.own@example.net"))
      end

      expect(response.parsed_body["next"]).to eq("sign_in")
      expect(other_invite.link.reload.user_id).to be_nil
    end
  end

  describe "closure time" do
    it "is the database's clock at the actual close, not the caller's or the sweep's start time" do
      link
      travel_to(1.hour.ago) do
        as_staff_in(company) { EmployeeLinks::Revoke.call(link: link, actor: staff, reason: "Seasonal layoff") }
      end
      expect(worker.reload.deactivated_at).to be_within(1.minute).of(ApplicationRecord.database_now)

      other = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", date_of_birth: Date.new(1988, 1, 2))
      other_login = create(:user, role: :portal_employee, company: company, name: "Avery Cruz", email: "avery@example.net",
        clerk_id: "user_avery", invitation_status: "accepted")
      EmployeeAccountLink.create!(user: other_login, company: company, employee: other, status: "former",
        activated_at: 1.year.ago, former_at: 1.day.ago, former_access_until: 1.day.from_now)
      travel_to(15.days.from_now) { ExpireEmployeeLinksJob.perform_now }

      closed_at = other_login.reload.deactivated_at
      expect(closed_at).to be_within(1.minute).of(ApplicationRecord.database_now)
      expect(RevokeEmployeeSessionsJob).to have_been_enqueued.with(other_login.id, closed_at.iso8601(6))
    end
  end

  describe "admin deactivation" do
    it "isn't lost to a reactivation that commits after the login was loaded" do
      close_last_link!
      allow_any_instance_of(User).to receive(:lock!).and_wrap_original do |original, *args|
        # The rehire reactivation commits between the controller's read and its lock.
        User.where(id: worker.id).update_all(active: true, deactivation_reason: nil)
        original.call(*args)
      end

      post "/api/v1/admin/users/#{worker.id}/deactivate", headers: bearer("user_staff").merge("X-Company-Id" => company.id.to_s)

      expect(response).to have_http_status(:ok)
      expect(worker.reload).to have_attributes(active: false, deactivation_reason: "deactivated")
      expect(worker.deactivated_at).to be_within(1.minute).of(ApplicationRecord.database_now)
    end

    def admin_deactivated_pending_sign_up
      invite = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: invite.code, email: "riley.own@example.net"))
      pending_user = invite.link.reload.user
      pending_user.update!(active: false, deactivation_reason: "deactivated")
      [ invite, pending_user ]
    end

    it "keeps its reason when the pending sign-up closes, so the row is never reused" do
      invite, pending_user = admin_deactivated_pending_sign_up

      # A retry on the same invite can't restart it.
      post_activation(activation_params(employee, code: invite.code, email: "riley.own@example.net"))
      expect(response.parsed_body["next"]).to eq("sign_in")

      as_staff_in(company) { EmployeeLinks::Revoke.call(link: invite.link.reload, actor: staff, reason: "Reissue") }
      expect(pending_user.reload).to have_attributes(active: false, deactivation_reason: "deactivated", invite_nonce_digest: nil)

      # (An email invite to that address is refused outright; a printed code isn't.)
      again = invite!(employee.reload, actor: staff, delivery: "code")
      expect do
        post_activation(activation_params(employee, code: again.code, email: "riley.own@example.net"))
      end.not_to(change { pending_user.reload.attributes.slice("active", "deactivation_reason") })
      expect(response.parsed_body["next"]).to eq("sign_in")
      expect(again.link.reload.user_id).to be_nil
    end

    it "keeps its reason when an existing login claims the invite" do
      invite, pending_user = admin_deactivated_pending_sign_up
      create(:user, role: :accountant, company: company, name: "Riley Santos", email: "riley.staff@example.net",
        clerk_id: "user_riley_staff")

      post "/api/v1/employee/links/claim", params: activation_params(employee, code: invite.code).to_json,
        headers: bearer("user_riley_staff", fva: [ 0, 0 ], two_factor_enabled: true).merge("CONTENT_TYPE" => "application/json")

      expect(response).to have_http_status(:created)
      expect(pending_user.reload).to have_attributes(active: false, deactivation_reason: "deactivated", invite_nonce_digest: nil)
      expect(EmployeeLinks.closed_pending_sign_up_for?(pending_user, employee)).to be(false)
    end
  end

  describe "retiring links while a sign-up attaches a login" do
    let!(:pending_link) { invite!(employee, actor: staff, delivery: "code").link }
    let!(:late_login) do
      create(:user, role: :portal_employee, company: company, name: "Riley Santos", email: "riley.late@example.net",
        invitation_status: "pending")
    end

    def open_links_with_attachment(times:)
      attempts = 0
      allow(EmployeeLinks).to receive(:lock_users!).and_wrap_original do |original, ids|
        attempts += 1
        # A sign-up attaches its login after the first read, before the link locks.
        EmployeeAccountLink.where(id: pending_link.id).update_all(user_id: late_login.id) if attempts <= times
        original.call(ids)
      end
      result = as_staff_in(company) do
        ApplicationRecord.transaction do
          employee.lock!
          EmployeeLinks::Retire.open_links(employee)
        end
      end
      [ result, attempts ]
    end

    it "releases the link locks and starts again from the employee lock instead of locking the login late" do
      links = attempts = nil
      locks = row_locks { links, attempts = open_links_with_attachment(times: 1) }

      expect(attempts).to eq(2)
      expect(links.map(&:id)).to eq([ pending_link.id ])
      # The link lock, released, then taken again; the attached login is
      # never locked after a link.
      expect(locks).to eq(%i[employee link link])
    end

    it "gives up after three attempts, leaving the caller's change to roll back" do
      expect { open_links_with_attachment(times: 3) }.to raise_error(EmployeeLinks::Error, /changed while it was being closed/)
    end
  end
end
